// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {Utilities} from "./utils/Utilities.sol";
import {console2} from "forge-std/console2.sol";

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {RolesAuthority, Authority} from "solmate/auth/authorities/RolesAuthority.sol";
import {MockBondCallback} from "./utils/mocks/MockBondCallback.sol";
import {MockFOTERC20} from "./utils/mocks/MockFOTERC20.sol";

import {IBondSDA} from "../interfaces/IBondSDA.sol";
import {IBondCallback} from "../interfaces/IBondCallback.sol";

import {BondFixedTermSDA} from "../BondFixedTermSDA.sol";
import {BondFixedTermTeller} from "../BondFixedTermTeller.sol";
import {BondAggregator} from "../BondAggregator.sol";
import {BondSampleCallback} from "../BondSampleCallback.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {FullMath} from "../lib/FullMath.sol";

/// @notice Tests instant swap bond purchases
contract BondFixedTermV3Test is Test {
    using FullMath for uint256;

    Utilities internal utils;
    address payable internal alice;
    address payable internal bob;
    address payable internal carol;
    address payable internal guardian;
    address payable internal policy;
    address payable internal treasury;
    address payable internal referrer;

    RolesAuthority internal auth;
    BondFixedTermSDA internal auctioneer;
    BondFixedTermTeller internal teller;
    BondAggregator internal aggregator;
    MockERC20 internal payoutToken;
    MockERC20 internal quoteToken;
    IBondSDA.MarketParams internal params;
    MockBondCallback internal callback;

    function setUp() public {
        vm.warp(51 * 365 * 24 * 60 * 60); // Set timestamp at roughly Jan 1, 2021 (51 years since Unix epoch)
        utils = new Utilities();
        address payable[] memory users = utils.createUsers(7);
        alice = users[0];
        bob = users[1];
        carol = users[2];
        guardian = users[3];
        policy = users[4];
        treasury = users[5];
        referrer = users[6];
        auth = new RolesAuthority(address(this), Authority(address(0)));

        // Deploy fresh contracts
        aggregator = new BondAggregator(guardian, auth);
        teller = new BondFixedTermTeller(policy, aggregator, guardian, auth);
        auctioneer = new BondFixedTermSDA(teller, aggregator, guardian, auth);

        // Configure access control on Authority
        // Role 0 - Guardian
        // Aggregator
        auth.setRoleCapability(
            uint8(0),
            address(aggregator),
            aggregator.registerAuctioneer.selector,
            true
        );

        // Teller
        auth.setRoleCapability(uint8(0), address(teller), teller.setProtocolFee.selector, true);

        // Auctioneer
        auth.setRoleCapability(
            uint8(0),
            address(auctioneer),
            auctioneer.setAllowNewMarkets.selector,
            true
        );
        auth.setRoleCapability(
            uint8(0),
            address(auctioneer),
            auctioneer.setCallbackAuthStatus.selector,
            true
        );

        // Role 1 - Policy
        // Auctioneer
        auth.setRoleCapability(
            uint8(1),
            address(auctioneer),
            auctioneer.setDefaults.selector,
            true
        );

        // Assign roles to addresses
        auth.setUserRole(guardian, uint8(0), true);
        auth.setUserRole(policy, uint8(1), true);

        // Configure protocol
        vm.prank(guardian);
        auctioneer.setCallbackAuthStatus(address(this), true);
        vm.prank(guardian);
        aggregator.registerAuctioneer(auctioneer);

        // Set fees for testing
        vm.prank(guardian);
        teller.setProtocolFee(uint48(100));

        vm.prank(referrer);
        teller.setReferrerFee(uint48(200));
    }

    function createMarket(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        bool _capacityInQuote,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    )
        internal
        returns (
            uint256 id,
            uint256 scale,
            uint256 price
        )
    {
        uint256 capacity = _capacityInQuote
            ? 500_000 * 10**uint8(int8(_quoteDecimals) - _quotePriceDecimals)
            : 100_000 * 10**uint8(int8(_payoutDecimals) - _payoutPriceDecimals);

        int8 scaleAdjustment = int8(_payoutDecimals) -
            int8(_quoteDecimals) -
            (_payoutPriceDecimals - _quotePriceDecimals) /
            2;

        scale = 10**uint8(36 + scaleAdjustment);

        price =
            5 *
            10 **
                uint8(
                    int8(36 + _quoteDecimals - _payoutDecimals) +
                        scaleAdjustment +
                        _payoutPriceDecimals -
                        _quotePriceDecimals
                );

        // PNG - payout token = $0.33
        // USDC/USDT LP - quote token = $2,000,000,000,000
        // price = 8 * 10**(scalingDecimals - 5)
        // capacity (in payout token) = 200_000 * 10**_payoutDecimals

        // console2.log("Price", initialPrice);
        // uint256 debt = _capacityInQuote ? capacity.mulDiv(scale, initialPrice) : capacity;
        // console2.log("Expected Debt", debt);
        // uint256 controlVariable = initialPrice.mulDiv(scale, debt);
        // console2.log("Control Variable", controlVariable);

        uint256 minimumPrice = 2 *
            10 **
                (
                    uint8(
                        int8(36 + _quoteDecimals - _payoutDecimals) +
                            scaleAdjustment +
                            _payoutPriceDecimals -
                            _quotePriceDecimals
                    )
                );
        uint32 debtBuffer = 500_000;
        uint48 vesting = 0; // Instant swaps
        uint48 conclusion = uint48(block.timestamp + 7 days);
        uint32 depositInterval = 24 hours;

        params = IBondSDA.MarketParams(
            payoutToken, // ERC20 payoutToken
            quoteToken, // ERC20 quoteToken
            address(callback), // address callbackAddr
            _capacityInQuote, // bool capacityIn
            capacity, // uint256 capacity
            price, // uint256 initialPrice
            minimumPrice, // uint256 minimumPrice
            debtBuffer, // uint32 debtBuffer
            vesting, // uint48 vesting (timestamp or duration)
            conclusion, // uint48 conclusion (timestamp)
            depositInterval, // uint32 depositInterval (duration)
            scaleAdjustment // int8 scaleAdjustment
        );

        id = auctioneer.createMarket(abi.encode(params));
    }

    function beforeEach(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        bool _capacityInQuote,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    )
        internal
        returns (
            uint256 id,
            uint256 scale,
            uint256 price
        )
    {
        // Deploy token and callback contracts with provided decimals
        payoutToken = new MockERC20("Payout Token", "BT", _payoutDecimals);
        quoteToken = new MockERC20("Quote Token", "QT", _quoteDecimals);
        callback = new MockBondCallback(payoutToken);

        // Mint tokens to users for testing
        uint256 testAmount = 1_000_000_000 * 10**uint8(int8(_quoteDecimals) - _quotePriceDecimals);

        quoteToken.mint(alice, testAmount);
        quoteToken.mint(bob, testAmount);
        quoteToken.mint(carol, testAmount);

        // Approve the teller for the tokens
        vm.prank(alice);
        quoteToken.approve(address(teller), testAmount);
        vm.prank(bob);
        quoteToken.approve(address(teller), testAmount);
        vm.prank(carol);
        quoteToken.approve(address(teller), testAmount);

        // Create market
        (id, scale, price) = createMarket(
            _payoutDecimals,
            _quoteDecimals,
            _capacityInQuote,
            _payoutPriceDecimals,
            _quotePriceDecimals
        );
    }

    function inFuzzRange(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    ) internal pure returns (bool) {
        if (
            _payoutDecimals > 18 || _payoutDecimals < 6 || _quoteDecimals > 18 || _quoteDecimals < 6
        ) return false;

        if (
            _payoutPriceDecimals < int8(-11) ||
            _payoutPriceDecimals > int8(12) ||
            _quotePriceDecimals < int8(-11) ||
            _quotePriceDecimals > int8(12)
        ) return false;

        // Don't test situations where the number of price decimals is greater than the number of
        // payout decimals, these are not likely to happen as it would create tokens whose smallest unit
        // would be a very high value (e.g. 1 wei > $ 1)
        if (
            _payoutPriceDecimals > int8(_payoutDecimals) ||
            _quotePriceDecimals > int8(_quoteDecimals)
        ) return false;

        // Otherwise, return true
        return true;
    }

    function testCorrectness_CreateMarket(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        bool _capacityInQuote,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    ) public {
        if (
            !inFuzzRange(_payoutDecimals, _quoteDecimals, _payoutPriceDecimals, _quotePriceDecimals)
        ) return;
        // uint8 _payoutDecimals = 18;
        // uint8 _quoteDecimals = 6;
        // bool _capacityInQuote = false;
        // int8 _priceShiftDecimals = -6;
        (uint256 id, uint256 expectedScale, uint256 price) = beforeEach(
            _payoutDecimals,
            _quoteDecimals,
            _capacityInQuote,
            _payoutPriceDecimals,
            _quotePriceDecimals
        );
        assertEq(id, 0);

        // Get variables for created Market
        (
            ,
            ,
            ,
            ,
            ,
            uint256 capacity,
            uint256 totalDebt,
            ,
            uint256 maxPayout,
            ,
            ,
            uint256 scale
        ) = auctioneer.markets(id);
        (uint256 controlVariable, uint256 maxDebt, , ) = auctioneer.terms(id);

        // Check scale set correctly
        assertEq(scale, expectedScale);

        // Check target debt set correctly
        uint256 expectedCapacity = _capacityInQuote
            ? capacity.mulDiv(expectedScale, price)
            : capacity;
        uint256 expectedDebt = expectedCapacity.mulDiv(5 days, 7 days);
        // console2.log("Payout Decimals", _payoutDecimals);
        // console2.log("Quote Decimals", _quoteDecimals);
        // console2.log("Capacity In Quote", _capacityInQuote);
        // console2.log("Capacity", capacity);
        // console2.log("Total Debt", totalDebt);
        // console2.log("Expected Debt", expectedDebt);
        assertEq(totalDebt, expectedDebt);

        // Check max payout set correctly
        uint256 expectedMaxPayout = (expectedCapacity * 24 hours) / 7 days;
        // console2.log("Max Payout", maxPayout);
        // console2.log("Expected Max Payout", expectedMaxPayout);
        assertEq(maxPayout, expectedMaxPayout);

        // Check max debt set correctly
        uint256 expectedMaxDebt = expectedDebt + ((expectedDebt * 500_000) / 1e5);
        assertEq(maxDebt, expectedMaxDebt);

        // Check control variable set correctly
        uint256 expectedCv = price.mulDiv(expectedScale, expectedDebt);
        // console2.log("Control Variable", controlVariable);
        // console2.log("Expected Control Variable", expectedCv);
        assertEq(controlVariable, expectedCv);
        assertGt(controlVariable, 100);
    }

    function testFail_CreateMarketParamOutOfBounds(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        bool _capacityInQuote,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    ) public {
        require(
            !inFuzzRange(
                _payoutDecimals,
                _quoteDecimals,
                _payoutPriceDecimals,
                _quotePriceDecimals
            ),
            "In fuzz range"
        );
        createMarket(
            _payoutDecimals,
            _quoteDecimals,
            _capacityInQuote,
            _payoutPriceDecimals,
            _quotePriceDecimals
        );
    }

    function testCorrectness_CannotCreateMarketWithInvalidParams() public {
        // Create tokens, etc.
        beforeEach(18, 18, true, 0, 0);

        // Setup market params
        IBondSDA.MarketParams memory params = IBondSDA.MarketParams(
            payoutToken, // ERC20 payoutToken
            quoteToken, // ERC20 quoteToken
            address(callback), // address callbackAddr
            false, // bool capacityIn
            1e22, // uint256 capacity
            5e36, // uint256 initialPrice
            3e36, // uint256 minimumPrice
            50_000, // uint32 debtBuffer
            uint48(0), // uint48 vesting (timestamp or duration)
            uint48(block.timestamp + 7 days), // uint48 conclusion (timestamp)
            1 days, // uint32 depositInterval (duration)
            0 // int8 scaleAdjustment
        );

        bytes memory err = abi.encodeWithSignature("Auctioneer_InvalidParams()");

        // Deposit Interval must be greater than 1 hour, but less than market duration
        params.depositInterval = uint32(1 hours) - 1;
        vm.expectRevert(err);
        auctioneer.createMarket(abi.encode(params));

        params.depositInterval = uint32(7 days) + 1;
        vm.expectRevert(err);
        auctioneer.createMarket(abi.encode(params));

        // Values within this range are valid
        params.depositInterval = uint32(1 days);
        auctioneer.createMarket(abi.encode(params));

        // Market duration must be greater than 1 day
        params.conclusion = uint48(block.timestamp) + 1 days - 1;
        vm.expectRevert(err);
        auctioneer.createMarket(abi.encode(params));

        params.conclusion = uint48(block.timestamp) + 3 days;
        auctioneer.createMarket(abi.encode(params));

        // Initial Price must be greater than Minimum Price
        err = abi.encodeWithSignature("Auctioneer_InitialPriceLessThanMin()");
        params.formattedInitialPrice = 1e36;
        params.formattedMinimumPrice = 2e36;
        vm.expectRevert(err);
        auctioneer.createMarket(abi.encode(params));

        params.formattedInitialPrice = 5e36;
        auctioneer.createMarket(abi.encode(params));
    }

    function testCorrectness_OnlyGuardianCanSetAllowNewMarkets() public {
        beforeEach(18, 18, true, 0, 0);

        // Don't allow normal users to change allowNewMarkets
        bytes memory err = abi.encodePacked("UNAUTHORIZED");
        vm.prank(alice);
        vm.expectRevert(err);
        auctioneer.setAllowNewMarkets(false);

        // Check that value is still true
        assert(auctioneer.allowNewMarkets());

        // Change allowNewMarkets to false as Guardian
        vm.prank(guardian);
        auctioneer.setAllowNewMarkets(false);

        // Check that the value is false
        assert(!auctioneer.allowNewMarkets());
    }

    function testFail_CannotCreateNewMarketsIfSunset() public {
        beforeEach(18, 18, true, 0, 0);

        // Change allowNewMarkets to false as Guardian
        vm.prank(guardian);
        auctioneer.setAllowNewMarkets(false);

        // Try to create a new market, expect to fail
        createMarket(18, 18, true, 0, 0);
    }

    function testCorrectness_OnlyGuardianCanSetCallbackAuthStatus() public {
        beforeEach(18, 18, true, 0, 0);

        // Don't allow normal users to set callbackAuthorized values
        bytes memory err = abi.encodePacked("UNAUTHORIZED");
        vm.prank(alice);
        vm.expectRevert(err);
        auctioneer.setCallbackAuthStatus(alice, true);

        // Check that alice is not authorized to use callbacks still
        assert(!auctioneer.callbackAuthorized(alice));

        // Change callbackAuthStatus to false as Guardian
        vm.prank(guardian);
        auctioneer.setCallbackAuthStatus(alice, true);

        // Check that alice is authorized to use callbacks now
        assert(auctioneer.callbackAuthorized(alice));
    }

    function testCorrectness_CannotCreateMarketWithCallbackUnlessAuthorized() public {
        beforeEach(18, 18, true, 0, 0);

        // Set market params
        IBondSDA.MarketParams memory _params = IBondSDA.MarketParams(
            payoutToken,
            quoteToken,
            address(callback),
            true,
            500_000 * 1e18,
            5 * 1e36,
            2 * 1e36,
            100_000,
            uint48(14 days),
            uint48(block.timestamp + 7 days),
            uint32(24 hours),
            0
        );

        // Attempt to create a market with a callback without authorization
        bytes memory err = abi.encodeWithSignature("Auctioneer_NotAuthorized()");
        vm.prank(alice);
        vm.expectRevert(err);
        auctioneer.createMarket(abi.encode(_params));

        // Change allowNewMarkets to false as Guardian
        vm.prank(guardian);
        auctioneer.setCallbackAuthStatus(alice, true);

        // Create a market with a callback now that alice is authorized
        vm.prank(alice);
        uint256 id = auctioneer.createMarket(abi.encode(_params));
        assertEq(id, 1);
    }

    function testCorrectness_RemovingFromWhitelistRevertsCurrentMarkets() public {
        // Create a market from this contract with a callback
        (uint256 id, uint256 price, uint256 scale) = beforeEach(18, 18, true, 0, 0);

        // Purchase a bond to ensure it's working as intended
        uint256 amount = 50e18;
        uint256 fee = amount.mulDiv(teller.getFee(referrer), 1e5);
        uint256 minAmountOut = (amount - fee).mulDiv(price, scale) / 2;

        vm.prank(alice);
        teller.purchase(alice, referrer, id, amount, minAmountOut);

        // Remove this contract from the whitelist
        vm.prank(guardian);
        auctioneer.setCallbackAuthStatus(address(this), false);

        // Try to purchase a bond again, expect to fail
        bytes memory err = abi.encodeWithSignature("Auctioneer_NotAuthorized()");
        vm.expectRevert(err);
        vm.prank(alice);
        teller.purchase(alice, referrer, id, amount, minAmountOut);
    }

    function testCorrectness_ConcludeInCorrectAmountOfTime() public {
        (uint256 id, , ) = beforeEach(18, 6, true, 0, 0);
        (, , , uint48 conclusion) = auctioneer.terms(id);

        assertEq(conclusion, uint48(block.timestamp + 7 days));
    }

    function testCorrectness_PurchaseBond(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        bool _capacityInQuote,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    ) public {
        if (
            !inFuzzRange(_payoutDecimals, _quoteDecimals, _payoutPriceDecimals, _quotePriceDecimals)
        ) return;
        // uint8 _payoutDecimals = 18;
        // uint8 _quoteDecimals = 6;
        // bool _capacityInQuote = false;
        // int8 _priceShiftDecimals = -12;
        (uint256 id, uint256 scale, uint256 price) = beforeEach(
            _payoutDecimals,
            _quoteDecimals,
            _capacityInQuote,
            _payoutPriceDecimals,
            _quotePriceDecimals
        );

        // Set variables for purchase
        uint256 amount = 50 * 10**uint8(int8(_quoteDecimals) - _quotePriceDecimals);
        uint256 fee = amount.mulDiv(teller.getFee(referrer), 1e5);
        uint256 minAmountOut = (amount - fee).mulDiv(scale, price) / 2; // set low to avoid slippage error

        // Purchase a bond
        uint256[3] memory balancesBefore = [
            quoteToken.balanceOf(alice),
            quoteToken.balanceOf(address(callback)),
            payoutToken.balanceOf(alice)
        ];

        vm.prank(alice);
        (uint256 payout, uint48 expiry) = teller.purchase(
            alice,
            referrer,
            id,
            amount,
            minAmountOut
        );
        uint256[3] memory balancesAfter = [
            quoteToken.balanceOf(alice),
            quoteToken.balanceOf(address(callback)),
            payoutToken.balanceOf(alice)
        ];

        assertEq(balancesAfter[0], balancesBefore[0] - amount);
        assertEq(balancesAfter[1], balancesBefore[1] + amount - fee);
        assertGe(balancesAfter[2], balancesBefore[2] + payout);
        assertEq(expiry, 0);
    }

    function testCorrectness_DebtDecay(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        bool _capacityInQuote,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    ) public {
        if (
            !inFuzzRange(_payoutDecimals, _quoteDecimals, _payoutPriceDecimals, _quotePriceDecimals)
        ) return;
        // uint8 _payoutDecimals = 18;
        // uint8 _quoteDecimals = 18;
        // bool _capacityInQuote = false;
        // int8 _priceShiftDecimals = 0;
        (uint256 id, uint256 scale, uint256 price) = beforeEach(
            _payoutDecimals,
            _quoteDecimals,
            _capacityInQuote,
            _payoutPriceDecimals,
            _quotePriceDecimals
        );

        // Get debt at the beginning
        uint256 startDebt = auctioneer.currentDebt(id);
        console2.log("Start Debt", startDebt);

        // Jump forward in time
        vm.warp(block.timestamp + 86400);

        // Get debt after time jump
        uint256 endDebt = auctioneer.currentDebt(id);
        console2.log("End Debt", endDebt);

        // Check that newDebt is less than oldDebt
        assertLt(endDebt, startDebt);
    }

    function testCorrectness_ControlDecay(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        bool _capacityInQuote,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    ) public {
        if (
            !inFuzzRange(_payoutDecimals, _quoteDecimals, _payoutPriceDecimals, _quotePriceDecimals)
        ) return;
        // uint8 _payoutDecimals = 18;
        // uint8 _quoteDecimals = 18;
        // bool _capacityInQuote = false;
        // int8 _priceShiftDecimals = 0;
        (uint256 id, uint256 scale, uint256 price) = beforeEach(
            _payoutDecimals,
            _quoteDecimals,
            _capacityInQuote,
            _payoutPriceDecimals,
            _quotePriceDecimals
        );

        // Get CV at the beginning
        (uint256 startCv, uint256 maxDebt, , ) = auctioneer.terms(id);
        uint256 startDebt = auctioneer.currentDebt(id);
        console2.log("Start Control Variable", startCv);
        console2.log("Start Max Debt", maxDebt);
        console2.log("Start Total Debt", startDebt);

        // Set variables for purchase
        uint256 amount = auctioneer.maxAmountAccepted(id, referrer);
        uint256 minAmountOut = amount.mulDiv(scale, price).mulDiv(
            1e5 - teller.getFee(referrer),
            1e5
        );

        // Purchase a bond so the market isn't too far behind
        vm.warp(block.timestamp + 43200);

        uint256 debt = auctioneer.currentDebt(id);
        console2.log("Debt Before Purchase", debt);
        vm.prank(alice);
        teller.purchase(alice, referrer, id, amount / 2, minAmountOut / 2);
        debt = auctioneer.currentDebt(id);
        console2.log("Debt After Purchase", debt);

        // Jump forward in time so the market gets behind
        vm.warp(block.timestamp + 86401);

        // Purchase a bond to trigger a tune
        vm.prank(alice);
        teller.purchase(alice, referrer, id, amount / 4, minAmountOut / 4);

        // Jump forward in time for 1/2 of the default tune interval
        vm.warp(block.timestamp + 86401 + 1800);

        // Purchase a small bond to trigger 1/2 of the adjustment
        amount = auctioneer.maxAmountAccepted(id, referrer);
        minAmountOut = amount.mulDiv(scale, price).mulDiv(1e5 - teller.getFee(referrer), 1e5);
        vm.prank(bob);
        teller.purchase(bob, referrer, id, amount / 10, minAmountOut / 10);

        // Get CV after bond
        (uint256 midCv, , , ) = auctioneer.terms(id);
        uint256 midDebt = auctioneer.currentDebt(id);
        console2.log("Mid CV", midCv);
        console2.log("Mid Debt", midDebt);

        // Jump forward in time for the full tune interval
        vm.warp(block.timestamp + 86400 + 3600);

        // Purchase a small bond to trigger the rest of the adjustment
        amount = auctioneer.maxAmountAccepted(id, referrer);
        minAmountOut = amount.mulDiv(scale, price).mulDiv(1e5 - teller.getFee(referrer), 1e5);
        vm.prank(bob);
        teller.purchase(bob, referrer, id, amount / 10, minAmountOut / 10);

        // Get CV after bond
        (uint256 endCv, , , ) = auctioneer.terms(id);
        console2.log("End CV", endCv);

        // Check that the CV has decreased and does so correctly over the adjustment
        assertLt(endCv, startCv);
        assertLt(midCv, startCv);
        assertLt(endCv, midCv);
    }

    function testCorrectness_StopControlAdjustment(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        bool _capacityInQuote,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    ) public {
        if (
            !inFuzzRange(_payoutDecimals, _quoteDecimals, _payoutPriceDecimals, _quotePriceDecimals)
        ) return;
        (uint256 id, uint256 scale, uint256 price) = beforeEach(
            _payoutDecimals,
            _quoteDecimals,
            _capacityInQuote,
            _payoutPriceDecimals,
            _quotePriceDecimals
        );

        // Get CV at the beginning
        (uint256 startCv, , , ) = auctioneer.terms(id);
        (, , , , , , , uint256 tuneIntervalCapacity, , ) = auctioneer.metadata(id);
        console2.log("Start Control Variable", startCv);
        console2.log("Tune Interval Capacity", tuneIntervalCapacity);

        // Set variables for purchase
        // uint256 amountScale = 10**uint8(int8(_quoteDecimals) - _quotePriceDecimals);
        uint256 amount = auctioneer.maxAmountAccepted(id, referrer);
        uint256 minAmountOut = amount.mulDiv(scale / 100, price);

        {
            (, , , bool active) = auctioneer.adjustments(id);
            (, , , , , uint256 capacity, uint256 totalDebt, , , , , ) = auctioneer.markets(id);
            (uint256 cv, , , ) = auctioneer.terms(id);
            console2.log("Control Variable", cv);
            console2.log("Capacity", capacity);
            console2.log("Total Debt", totalDebt);
            console2.log("Active", active);
        }

        // Purchase a bond early so the market isn't too far behind
        vm.prank(alice);
        teller.purchase(alice, referrer, id, amount / 3, minAmountOut / 3);

        // Jump forward in time past the tuning interval
        vm.warp(block.timestamp + 86401);

        // Purchase a bond to trigger a tune
        vm.prank(alice);
        teller.purchase(alice, referrer, id, amount / 100, minAmountOut / 100);

        {
            (, , , bool active) = auctioneer.adjustments(id);
            (, , , , , uint256 capacity, uint256 totalDebt, , , , , ) = auctioneer.markets(id);
            (uint256 cv, , , ) = auctioneer.terms(id);
            console2.log("Control Variable", cv);
            console2.log("Capacity", capacity);
            console2.log("Total Debt", totalDebt);
            console2.log("Active", active);
        }

        // Jump forward in time for part of the default tune adjustment
        vm.warp(block.timestamp + 86401 + 300);

        // Purchase a bond trigger part of the adjustment
        vm.prank(bob);
        teller.purchase(bob, referrer, id, amount / 100, minAmountOut / 100);

        // Get CV after bond
        (uint256 midCv, , , ) = auctioneer.terms(id);
        console2.log("Mid CV", midCv);
        assertLt(midCv, startCv);

        vm.warp(block.timestamp + 86401 + 300 + 5);

        // Purchase several max bonds to cancel the adjustment and re-tune up
        amount = auctioneer.maxAmountAccepted(id, referrer);
        price = auctioneer.marketPrice(id);
        minAmountOut = amount.mulDiv(scale / 100, price);
        vm.prank(alice);
        teller.purchase(alice, referrer, id, amount, minAmountOut);

        amount = auctioneer.maxAmountAccepted(id, referrer);
        price = auctioneer.marketPrice(id);
        minAmountOut = amount.mulDiv(scale / 100, price);
        vm.prank(bob);
        teller.purchase(bob, referrer, id, amount, minAmountOut);

        amount = auctioneer.maxAmountAccepted(id, referrer);
        price = auctioneer.marketPrice(id);
        minAmountOut = amount.mulDiv(scale / 100, price);
        vm.prank(carol);
        teller.purchase(carol, referrer, id, amount, minAmountOut);

        amount = auctioneer.maxAmountAccepted(id, referrer);
        price = auctioneer.marketPrice(id);
        minAmountOut = amount.mulDiv(scale / 100, price);
        vm.prank(alice);
        teller.purchase(alice, referrer, id, amount, minAmountOut);

        amount = auctioneer.maxAmountAccepted(id, referrer);
        price = auctioneer.marketPrice(id);
        minAmountOut = amount.mulDiv(scale / 100, price);
        vm.prank(bob);
        teller.purchase(bob, referrer, id, amount, minAmountOut);

        amount = auctioneer.maxAmountAccepted(id, referrer);
        price = auctioneer.marketPrice(id);
        minAmountOut = amount.mulDiv(scale / 100, price);
        vm.prank(carol);
        teller.purchase(carol, referrer, id, amount, minAmountOut);

        amount = auctioneer.maxAmountAccepted(id, referrer);
        price = auctioneer.marketPrice(id);
        minAmountOut = amount.mulDiv(scale / 100, price);
        vm.prank(alice);
        teller.purchase(alice, referrer, id, amount, minAmountOut);

        amount = auctioneer.maxAmountAccepted(id, referrer);
        price = auctioneer.marketPrice(id);
        minAmountOut = amount.mulDiv(scale / 100, price);
        vm.prank(bob);
        teller.purchase(bob, referrer, id, amount, minAmountOut);

        amount = auctioneer.maxAmountAccepted(id, referrer);
        price = auctioneer.marketPrice(id);
        minAmountOut = amount.mulDiv(scale / 100, price);
        vm.prank(carol);
        teller.purchase(carol, referrer, id, amount, minAmountOut);

        {
            (, , , bool active) = auctioneer.adjustments(id);
            (, , , , , uint256 capacity, uint256 totalDebt, , , , , ) = auctioneer.markets(id);
            (uint256 cv, , , ) = auctioneer.terms(id);
            console2.log("Control Variable", cv);
            console2.log("Capacity", capacity);
            console2.log("Total Debt", totalDebt);
            console2.log("Active", active);
        }

        // Get CV after bonds
        (uint256 endCv, , , ) = auctioneer.terms(id);
        console2.log("End CV", endCv);
        assertGt(endCv, midCv);
    }

    function testCorrectness_MarketPrice(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        bool _capacityInQuote,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    ) public {
        if (
            !inFuzzRange(_payoutDecimals, _quoteDecimals, _payoutPriceDecimals, _quotePriceDecimals)
        ) return;

        (uint256 id, , uint256 expectedPrice) = beforeEach(
            _payoutDecimals,
            _quoteDecimals,
            _capacityInQuote,
            _payoutPriceDecimals,
            _quotePriceDecimals
        );

        uint256 minPrice = expectedPrice.mulDiv(2, 5);

        uint256 price = aggregator.marketPrice(id);

        assertEq(price, expectedPrice);
        vm.warp(block.timestamp + 4 days);
        assertEq(aggregator.marketPrice(id), minPrice);
    }

    function testCorrectness_MarketScale(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        bool _capacityInQuote,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    ) public {
        if (
            !inFuzzRange(_payoutDecimals, _quoteDecimals, _payoutPriceDecimals, _quotePriceDecimals)
        ) return;

        (uint256 id, uint256 expectedScale, ) = beforeEach(
            _payoutDecimals,
            _quoteDecimals,
            _capacityInQuote,
            _payoutPriceDecimals,
            _quotePriceDecimals
        );

        uint256 scale = aggregator.marketScale(id);

        assertEq(scale, expectedScale);
    }

    function testCorrectness_PayoutFor(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        bool _capacityInQuote,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    ) public {
        if (
            !inFuzzRange(_payoutDecimals, _quoteDecimals, _payoutPriceDecimals, _quotePriceDecimals)
        ) return;

        (uint256 id, uint256 scale, uint256 price) = beforeEach(
            _payoutDecimals,
            _quoteDecimals,
            _capacityInQuote,
            _payoutPriceDecimals,
            _quotePriceDecimals
        );

        uint256 amountIn = 5 * 10**uint8(int8(_quoteDecimals) - _quotePriceDecimals);
        uint256 fee = amountIn.mulDiv(teller.getFee(referrer), 1e5);
        uint256 payout = aggregator.payoutFor(amountIn, id, referrer);
        uint256 expectedPayout = (amountIn - fee).mulDiv(scale, price);

        // Check that the values are equal
        assertEq(payout, expectedPayout);
    }

    function testCorrectness_OnlyOwnerCanUpdateIntervals() public {
        (uint256 id, , ) = beforeEach(18, 18, false, 0, 0);

        // Attempt to set intervals with a non-owner account
        bytes memory err = abi.encodeWithSignature("Auctioneer_OnlyMarketOwner()");
        vm.expectRevert(err);
        vm.prank(alice);
        auctioneer.setIntervals(id, [uint32(40 hours), uint32(2 hours), uint32(10 days)]);

        // Set new intervals with owner account
        uint32 expectedTuneInterval = 30 hours;
        uint32 expectedTuneAdjustmentDelay = 4 hours;
        uint32 expectedDebtDecayInterval = 5 days;

        auctioneer.setIntervals(
            id,
            [expectedTuneInterval, expectedTuneAdjustmentDelay, expectedDebtDecayInterval]
        );

        (
            ,
            ,
            ,
            ,
            uint32 tuneInterval,
            uint32 tuneAdjustmentDelay,
            uint32 debtDecayInterval,
            ,
            ,

        ) = auctioneer.metadata(id);

        assertEq(tuneInterval, expectedTuneInterval);
        assertEq(tuneAdjustmentDelay, expectedTuneAdjustmentDelay);
        assertEq(debtDecayInterval, expectedDebtDecayInterval);
    }

    function testCorrectness_cannotSetIntervalsWithInvalidParams() public {
        (uint256 id, , ) = beforeEach(18, 18, false, 0, 0);

        // Attempt to set intervals with a tune interval less than the deposit interval
        bytes memory err = abi.encodeWithSignature("Auctioneer_InvalidParams()");
        vm.expectRevert(err);
        auctioneer.setIntervals(id, [uint32(20 hours), uint32(4 hours), uint32(5 days)]);

        // Attempt to set intervals with a tune adjustment delay greater than the tune interval
        vm.expectRevert(err);
        auctioneer.setIntervals(id, [uint32(30 hours), uint32(35 hours), uint32(5 days)]);

        // Attempt to set intervals with a debt decay interval less than the minimum
        vm.expectRevert(err);
        auctioneer.setIntervals(id, [uint32(30 hours), uint32(4 hours), uint32(1 days)]);

        // Attempt to set intervals with zero values
        vm.expectRevert(err);
        auctioneer.setIntervals(id, [uint32(0), uint32(4 hours), uint32(5 days)]);

        vm.expectRevert(err);
        auctioneer.setIntervals(id, [uint32(30 hours), uint32(0), uint32(5 days)]);

        vm.expectRevert(err);
        auctioneer.setIntervals(id, [uint32(30 hours), uint32(4 hours), uint32(0)]);

        vm.expectRevert(err);
        auctioneer.setIntervals(id, [uint32(0), uint32(0), uint32(0)]);

        // Attempt to set intervals on a closed market (should fail)
        auctioneer.closeMarket(id);

        vm.expectRevert(err);
        auctioneer.setIntervals(id, [uint32(40 hours), uint32(2 hours), uint32(10 days)]);
    }

    function testCorrectness_MarketOwnershipPushAndPull() public {
        (uint256 id, , ) = beforeEach(18, 18, false, 0, 0);

        // Attempt to set new owner with non-owner account
        bytes memory err1 = abi.encodeWithSignature("Auctioneer_OnlyMarketOwner()");
        vm.expectRevert(err1);
        vm.prank(alice);
        auctioneer.pushOwnership(id, alice);

        // Push new owner with owner account
        auctioneer.pushOwnership(id, bob);

        // Check that newOwner is set, but owner is not
        (address owner, , , , , , , , , , , ) = auctioneer.markets(id);
        address newOwner = auctioneer.newOwners(id);
        assertEq(owner, address(this));
        assertEq(newOwner, bob);

        // Try to pull with a different address
        bytes memory err2 = abi.encodeWithSignature("Auctioneer_NotAuthorized()");
        vm.expectRevert(err2);
        vm.prank(alice);
        auctioneer.pullOwnership(id);

        // Pull ownership with newOwner account
        vm.prank(bob);
        auctioneer.pullOwnership(id);

        (owner, , , , , , , , , , , ) = auctioneer.markets(id);
        newOwner = auctioneer.newOwners(id);
        assertEq(owner, bob);
        assertEq(newOwner, bob);
    }

    function testCorrectness_OnlyPolicyCanSetDefaultIntervals() public {
        beforeEach(18, 18, false, 0, 0);

        // Attempt to set new intervals with non-policy account
        bytes memory err = abi.encodePacked("UNAUTHORIZED");
        vm.expectRevert(err);
        vm.prank(alice);
        auctioneer.setDefaults(
            [
                uint32(6 hours),
                uint32(6 hours),
                uint32(6 hours),
                uint32(6 hours),
                uint32(6 hours),
                uint32(100_000)
            ]
        );

        // Set new intervals as policy
        uint32 expDefaultTuneInterval = 12 hours;
        uint32 expDefaultTuneAdjustment = 4 hours;
        uint32 expMinDebtDecayInterval = 5 days;
        uint32 expMinDepositInterval = 2 hours;
        uint32 expMinMarketDuration = 2 days;
        uint32 expMinDebtBuffer = 20_000;

        vm.prank(policy);
        auctioneer.setDefaults(
            [
                expDefaultTuneInterval,
                expDefaultTuneAdjustment,
                expMinDebtDecayInterval,
                expMinDepositInterval,
                expMinMarketDuration,
                expMinDebtBuffer
            ]
        );

        assertEq(auctioneer.defaultTuneInterval(), expDefaultTuneInterval);
        assertEq(auctioneer.defaultTuneAdjustment(), expDefaultTuneAdjustment);
        assertEq(auctioneer.minDebtDecayInterval(), expMinDebtDecayInterval);
        assertEq(auctioneer.minDepositInterval(), expMinDepositInterval);
        assertEq(auctioneer.minMarketDuration(), expMinMarketDuration);
        assertEq(auctioneer.minDebtBuffer(), expMinDebtBuffer);
    }

    function testCorrectness_FeesPaidInQuoteToken() public {
        (uint256 id, uint256 scale, uint256 price) = beforeEach(18, 18, false, 0, 0);

        // Purchase a bond to accumulate a fee for protocol
        uint256 amount = 5000 * 1e18;
        uint256 minAmountOut = amount.mulDiv(1e5 - teller.getFee(referrer), 1e5).mulDiv(
            scale,
            price
        );

        vm.prank(alice);
        teller.purchase(alice, referrer, id, amount, minAmountOut);

        // Get fees and check balances
        ERC20[] memory tokens = new ERC20[](1);
        tokens[0] = quoteToken;

        vm.prank(policy);
        teller.claimFees(tokens, treasury);

        vm.prank(referrer);
        teller.claimFees(tokens, referrer);

        assertEq(quoteToken.balanceOf(treasury), amount.mulDiv(100, 1e5));
        assertEq(quoteToken.balanceOf(referrer), amount.mulDiv(200, 1e5));
    }

    function testCorrectness_OnlyGuardianCanSetProtocolFee() public {
        beforeEach(18, 18, false, 0, 0);

        // Attempt to set new fees with non-guardian account
        bytes memory err = abi.encodePacked("UNAUTHORIZED");
        vm.expectRevert(err);
        vm.prank(alice);
        teller.setProtocolFee(0);

        // Attempt to set a fee greater than the max (5%)
        err = abi.encodeWithSignature("Teller_InvalidParams()");
        vm.expectRevert(err);
        vm.prank(guardian);
        teller.setProtocolFee(6e3);

        // Set new fees as guardian
        uint48 expFee = 500;

        vm.prank(guardian);
        teller.setProtocolFee(expFee);

        assertEq(teller.protocolFee(), expFee);
    }

    function testCorrectness_ReferrerCanSetOwnFee() public {
        beforeEach(18, 18, false, 0, 0);

        // Attempt to set fee above the max value (5e4) and expect to fail
        bytes memory err = abi.encodeWithSignature("Teller_InvalidParams()");
        vm.expectRevert(err);
        vm.prank(referrer);
        teller.setReferrerFee(6e4);

        // Confirm that the fee is still set to the initialized value
        assertEq(teller.referrerFees(referrer), uint48(200));

        // Set the fee to an allowed value
        uint48 expFee = 500;
        vm.prank(referrer);
        teller.setReferrerFee(expFee);

        // Confirm that the fee is set to the new value
        assertEq(teller.referrerFees(referrer), expFee);
    }

    function testCorrectness_getFee() public {
        beforeEach(18, 18, false, 0, 0);

        // Check that the fee set the protocol is correct (use zero address for referrer)
        assertEq(teller.getFee(address(0)), uint48(100));

        // Check that the fee set the protocol + referrer is correct
        assertEq(teller.getFee(referrer), uint48(300));
    }

    function testCorrectness_liveMarketsBetween() public {
        // Setup tests and create multiple markets
        (uint256 id1, , ) = beforeEach(18, 18, false, 0, 0);
        (uint256 id2, , ) = createMarket(18, 6, true, 3, 0);
        (uint256 id3, , ) = createMarket(9, 6, true, 1, 0);
        (uint256 id4, , ) = createMarket(18, 9, true, -2, 1);
        (uint256 id5, , ) = createMarket(6, 9, true, 0, 1);

        // Get first 3 markets
        {
            uint256[] memory liveMarkets = aggregator.liveMarketsBetween(0, 3);
            assertEq(liveMarkets.length, 3);
            assertEq(liveMarkets[0], id1);
            assertEq(liveMarkets[1], id2);
            assertEq(liveMarkets[2], id3);
        }

        // Get last 3 markets
        {
            uint256[] memory liveMarkets = aggregator.liveMarketsBetween(2, 5);
            assertEq(liveMarkets.length, 3);
            assertEq(liveMarkets[0], id3);
            assertEq(liveMarkets[1], id4);
            assertEq(liveMarkets[2], id5);
        }

        // Get middle 3 markets
        {
            uint256[] memory liveMarkets = aggregator.liveMarketsBetween(1, 4);
            assertEq(liveMarkets.length, 3);
            assertEq(liveMarkets[0], id2);
            assertEq(liveMarkets[1], id3);
            assertEq(liveMarkets[2], id4);
        }

        // Get 1 market
        {
            uint256[] memory liveMarkets = aggregator.liveMarketsBetween(1, 2);
            assertEq(liveMarkets.length, 1);
            assertEq(liveMarkets[0], id2);
        }
    }

    function testCorrectness_liveMarketsFor() public {
        // Setup tests and create multiple markets
        (uint256 id1, , ) = beforeEach(18, 18, false, 3, 0);

        payoutToken = new MockERC20("Payout Token Two", "BT2", 18);
        quoteToken = new MockERC20("Quote Token Two", "BT2", 6);
        (uint256 id2, , ) = createMarket(18, 6, true, 0, 0);

        (, ERC20 payoutToken1, ERC20 quoteToken1, , , , , , , , , ) = auctioneer.markets(id1);
        (, ERC20 payoutToken2, ERC20 quoteToken2, , , , , , , , , ) = auctioneer.markets(id2);

        uint256 id3 = auctioneer.createMarket(
            abi.encode(
                IBondSDA.MarketParams(
                    quoteToken2,
                    payoutToken1,
                    address(callback),
                    true,
                    500_000 * 1e18,
                    5 * 1e36,
                    2 * 1e36,
                    100_000,
                    uint48(14 days),
                    uint48(block.timestamp + 7 days),
                    uint32(24 hours),
                    0
                )
            )
        );

        // Get markets for tokens
        {
            uint256[] memory markets = aggregator.liveMarketsFor(address(payoutToken1), true);
            assertEq(markets.length, 1);
            assertEq(markets[0], id1);
        }
        {
            uint256[] memory markets = aggregator.liveMarketsFor(address(payoutToken1), false);
            assertEq(markets.length, 1);
            assertEq(markets[0], id3);
        }
        {
            uint256[] memory markets = aggregator.liveMarketsFor(address(payoutToken2), true);
            assertEq(markets.length, 1);
            assertEq(markets[0], id2);
        }
        {
            uint256[] memory markets = aggregator.liveMarketsFor(address(payoutToken2), false);
            assertEq(markets.length, 0);
        }
        {
            uint256[] memory markets = aggregator.liveMarketsFor(address(quoteToken1), true);
            assertEq(markets.length, 0);
        }
        {
            uint256[] memory markets = aggregator.liveMarketsFor(address(quoteToken1), false);
            assertEq(markets.length, 1);
            assertEq(markets[0], id1);
        }
        {
            uint256[] memory markets = aggregator.liveMarketsFor(address(quoteToken2), true);
            assertEq(markets.length, 1);
            assertEq(markets[0], id3);
        }
        {
            uint256[] memory markets = aggregator.liveMarketsFor(address(quoteToken2), false);
            assertEq(markets.length, 1);
            assertEq(markets[0], id2);
        }
    }

    function testCorrectness_marketsFor() public {
        // Setup tests and create multiple markets
        (uint256 id1, , ) = beforeEach(18, 18, false, 3, 0);

        payoutToken = new MockERC20("Payout Token Two", "BT2", 18);
        quoteToken = new MockERC20("Quote Token Two", "BT2", 6);
        (uint256 id2, , ) = createMarket(18, 6, true, 0, 0);

        (, ERC20 payoutToken1, ERC20 quoteToken1, , , , , , , , , ) = auctioneer.markets(id1);
        (, ERC20 payoutToken2, ERC20 quoteToken2, , , , , , , , , ) = auctioneer.markets(id2);

        uint256 id3 = auctioneer.createMarket(
            abi.encode(
                IBondSDA.MarketParams(
                    quoteToken2,
                    payoutToken1,
                    address(callback),
                    true,
                    500_000 * 1e18,
                    5 * 1e36,
                    2 * 1e36,
                    100_000,
                    uint48(14 days),
                    uint48(block.timestamp + 7 days),
                    uint32(24 hours),
                    0
                )
            )
        );

        // Get markets for tokens
        {
            uint256[] memory markets = aggregator.marketsFor(
                address(payoutToken1),
                address(quoteToken1)
            );
            assertEq(markets.length, 1);
            assertEq(markets[0], id1);
        }
        {
            uint256[] memory markets = aggregator.marketsFor(
                address(payoutToken1),
                address(quoteToken2)
            );
            assertEq(markets.length, 0);
        }
        {
            uint256[] memory markets = aggregator.marketsFor(
                address(payoutToken2),
                address(quoteToken1)
            );
            assertEq(markets.length, 0);
        }
        {
            uint256[] memory markets = aggregator.marketsFor(
                address(payoutToken2),
                address(quoteToken2)
            );
            assertEq(markets.length, 1);
            assertEq(markets[0], id2);
        }
        {
            uint256[] memory markets = aggregator.marketsFor(
                address(quoteToken1),
                address(payoutToken1)
            );
            assertEq(markets.length, 0);
        }
        {
            uint256[] memory markets = aggregator.marketsFor(
                address(quoteToken1),
                address(payoutToken2)
            );
            assertEq(markets.length, 0);
        }
        {
            uint256[] memory markets = aggregator.marketsFor(
                address(quoteToken2),
                address(payoutToken1)
            );
            assertEq(markets.length, 1);
            assertEq(markets[0], id3);
        }
        {
            uint256[] memory markets = aggregator.marketsFor(
                address(quoteToken2),
                address(payoutToken2)
            );
            assertEq(markets.length, 0);
        }
    }

    function testCorrectness_findMarketFor() public {
        // Setup tests and create multiple markets
        (uint256 id1, , ) = beforeEach(18, 18, false, 3, 0);

        payoutToken = new MockERC20("Payout Token Two", "BT2", 18);
        quoteToken = new MockERC20("Quote Token Two", "BT2", 6);
        (uint256 id2, , ) = createMarket(18, 6, true, 0, 0);

        (, ERC20 payoutToken1, ERC20 quoteToken1, , , , , , , , , ) = auctioneer.markets(id1);
        (, ERC20 payoutToken2, ERC20 quoteToken2, , , , , , , , , ) = auctioneer.markets(id2);

        uint256 id3 = auctioneer.createMarket(
            abi.encode(
                IBondSDA.MarketParams(
                    quoteToken2,
                    payoutToken1,
                    address(callback),
                    true,
                    500_000 * 1e18,
                    5 * 1e36,
                    2 * 1e36,
                    100_000,
                    uint48(14 days),
                    uint48(block.timestamp + 7 days),
                    uint32(24 hours),
                    0
                )
            )
        );

        // Get markets for tokens
        {
            uint256 marketId = aggregator.findMarketFor(
                address(payoutToken1),
                address(quoteToken1),
                5e21,
                1,
                block.timestamp + 30 days
            );
            assertEq(marketId, id1);
        }
        {
            uint256 marketId = aggregator.findMarketFor(
                address(payoutToken2),
                address(quoteToken2),
                5e6,
                1,
                block.timestamp + 30 days
            );
            assertEq(marketId, id2);
        }
        {
            uint256 marketId = aggregator.findMarketFor(
                address(quoteToken2),
                address(payoutToken1),
                5e18,
                1,
                block.timestamp + 30 days
            );
            assertEq(marketId, id3);
        }
    }

    function testCorrectness_liveMarketsBy() public {
        // Setup tests and create multiple markets
        (uint256 id1, , ) = beforeEach(18, 18, false, 3, 0);
        (uint256 id2, , ) = createMarket(18, 18, false, 3, 0);

        // Approve new owner for callback
        vm.prank(guardian);
        auctioneer.setCallbackAuthStatus(bob, true);

        // Create a market with a new owner
        vm.prank(bob);
        uint256 id3 = auctioneer.createMarket(
            abi.encode(
                IBondSDA.MarketParams(
                    payoutToken,
                    quoteToken,
                    address(callback),
                    true,
                    500_000 * 1e18,
                    5 * 1e36,
                    2 * 1e36,
                    100_000,
                    uint48(14 days),
                    uint48(block.timestamp + 7 days),
                    uint32(24 hours),
                    0
                )
            )
        );

        // Get markets by owners
        {
            uint256[] memory markets = aggregator.liveMarketsBy(address(this));
            assertEq(markets.length, 2);
            assertEq(markets[0], id1);
            assertEq(markets[1], id2);
        }
        {
            uint256[] memory markets = aggregator.liveMarketsBy(bob);
            assertEq(markets.length, 1);
            assertEq(markets[0], id3);
        }
    }

    function testCorrectness_ProtocolAndReferrerCanRedeemFees() public {
        // Create market and purchase a couple bonds so there are fees to claim
        (uint256 id, uint256 scale, uint256 price) = beforeEach(18, 18, false, 0, 0);
        uint256 amount = 50 * 1e18;
        uint256 minAmountOut = amount.mulDiv(scale / 2, price);

        vm.prank(alice);
        teller.purchase(alice, referrer, id, amount, minAmountOut);

        vm.prank(alice);
        teller.purchase(alice, referrer, id, amount, minAmountOut);

        vm.prank(alice);
        teller.purchase(alice, referrer, id, amount, minAmountOut);

        // Try to redeem fees as non-protocol account
        ERC20[] memory tokens = new ERC20[](1);
        tokens[0] = quoteToken;
        uint256 totalAmount = amount * 3;

        // Redeem fees for protocol
        {
            uint256 startBal = quoteToken.balanceOf(treasury);
            vm.prank(policy);
            teller.claimFees(tokens, treasury);
            uint256 endBal = quoteToken.balanceOf(treasury);
            assertEq(endBal, startBal + totalAmount.mulDiv(100, 1e5));
        }

        // Redeem fees for referrer
        {
            uint256 startBal = quoteToken.balanceOf(referrer);
            vm.prank(referrer);
            teller.claimFees(tokens, referrer);
            uint256 endBal = quoteToken.balanceOf(referrer);
            assertEq(endBal, startBal + totalAmount.mulDiv(200, 1e5));
        }
    }

    function testCorrectness_FOTQuoteTokenFailsPurchase() public {
        // Initialize protocol
        beforeEach(18, 18, false, 0, 0);

        // Deploy fee-on-transfer (FOT) token
        MockFOTERC20 fotToken = new MockFOTERC20("FOT Token", "FOT", 18, bob, 1e3); // 1% fee on transfer to bob

        // Send FOT token to user for purchase and approve teller for FOT token
        fotToken.mint(alice, 5000 * 1e18);

        vm.prank(alice);
        fotToken.approve(address(teller), 5000 * 1e18);

        // Create market with FOT token as quote token
        uint256 price = 5 * 1e36;
        uint256 scale = 1e36;
        uint256 id = auctioneer.createMarket(
            abi.encode(
                IBondSDA.MarketParams(
                    payoutToken,
                    fotToken,
                    address(callback),
                    true,
                    500_000 * 1e18,
                    price,
                    2 * 1e36,
                    100_000,
                    uint48(14 days),
                    uint48(block.timestamp + 7 days),
                    uint32(24 hours),
                    0
                )
            )
        );

        // Try to purchase a bond and expect revert
        uint256 amount = 50 * 1e18;
        uint256 minAmountOut = amount.mulDiv(scale / 2, price);

        bytes memory err = abi.encodeWithSignature("Teller_UnsupportedToken()");
        vm.prank(alice);
        vm.expectRevert(err);
        teller.purchase(alice, referrer, id, amount, minAmountOut);
    }

    function testCorrectness_FOTPayoutTokenFailsPurchase() public {
        // Initialize protocol
        beforeEach(18, 18, false, 0, 0);

        // Deploy fee-on-transfer (FOT) token
        MockFOTERC20 fotToken = new MockFOTERC20("FOT Token", "FOT", 18, bob, 1e3); // 1% fee on transfer to bob
        BondSampleCallback fotCallback = new BondSampleCallback(aggregator);

        // Mint FOT token to callback for payouts
        fotToken.mint(address(fotCallback), 1000 * 1e18);

        // Create market with FOT token as payout token
        uint256 price = 5 * 1e36;
        uint256 scale = 1e36;
        uint256 id = auctioneer.createMarket(
            abi.encode(
                IBondSDA.MarketParams(
                    fotToken,
                    quoteToken,
                    address(fotCallback),
                    true,
                    500_000 * 1e18,
                    price,
                    2 * 1e36,
                    100_000,
                    uint48(14 days),
                    uint48(block.timestamp + 7 days),
                    uint32(24 hours),
                    0
                )
            )
        );

        // Register market on callback
        fotCallback.whitelist(address(teller), id);

        // Try to purchase a bond and expect revert
        uint256 amount = 50 * 1e18;
        uint256 minAmountOut = amount.mulDiv(scale / 2, price);

        bytes memory err = abi.encodeWithSignature("Teller_InvalidCallback()");
        vm.prank(alice);
        vm.expectRevert(err);
        teller.purchase(alice, referrer, id, amount, minAmountOut);
    }
}
