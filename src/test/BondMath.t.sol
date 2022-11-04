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

contract BondMathTest is Test {
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
        // price = 10000000000000000001;

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
        // uint256 minimumPrice = 4444444444444444444;
        uint32 debtBuffer = 200_000;
        uint48 vesting = 7 days; // fixed term of 7 days
        uint48 conclusion = uint48(block.timestamp + 7 days);
        uint32 depositInterval = 24 hours;

        params = IBondSDA.MarketParams(
            payoutToken, // ERC20 payoutToken
            quoteToken, // ERC20 quoteToken
            address(0), // address callbackAddr - No callback in V1
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
        // Deploy token contracts with provided decimals
        payoutToken = new MockERC20("Payout Token", "BT", _payoutDecimals);
        quoteToken = new MockERC20("Quote Token", "QT", _quoteDecimals);

        // Mint tokens to users for testing
        uint256 testAmount = 1_000_000_000 * 10**uint8(int8(_quoteDecimals) - _quotePriceDecimals);

        quoteToken.mint(alice, testAmount);
        quoteToken.mint(bob, testAmount);
        quoteToken.mint(carol, testAmount);
        payoutToken.mint(
            address(this),
            1_000_000_000 * 10**uint8(int8(_payoutDecimals) - _payoutPriceDecimals)
        );

        // Approve the teller for the tokens
        vm.prank(alice);
        quoteToken.approve(address(teller), testAmount);
        vm.prank(bob);
        quoteToken.approve(address(teller), testAmount);
        vm.prank(carol);
        quoteToken.approve(address(teller), testAmount);

        // Approve the teller from this address for payouts
        payoutToken.approve(
            address(teller),
            1_000_000_000 * 10**uint8(int8(_payoutDecimals) - _payoutPriceDecimals)
        );

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

    function testCorrectness_PriceMathDuality(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        bool _capacityInQuote,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    ) public {
        if (
            !inFuzzRange(_payoutDecimals, _quoteDecimals, _payoutPriceDecimals, _quotePriceDecimals)
        ) return;
        // Create market
        // uint8 _payoutDecimals = 18;
        // uint8 _quoteDecimals = 18;
        // bool _capacityInQuote = false;
        // int8 _payoutPriceDecimals = 0;
        // int8 _quotePriceDecimals = 0;

        (uint256 id, uint256 scale, uint256 price) = beforeEach(
            _payoutDecimals,
            _quoteDecimals,
            _capacityInQuote,
            _payoutPriceDecimals,
            _quotePriceDecimals
        );

        // Check if marketPrice returned equals the initialized price
        uint256 marketPrice = auctioneer.marketPrice(id);
        assertEq(marketPrice, price);

        // Get control variable and debt from market
        uint256 debt = auctioneer.currentDebt(id);
        uint256 cv = auctioneer.currentControlVariable(id);

        // Check if price equation is reversible after creation
        assertEq(price, cv.mulDivUp(debt, scale));
        assertEq(cv, price.mulDiv(scale, debt));
    }

    function testCorrectness_PayoutConversionMath(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        bool _capacityInQuote,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    ) public {
        if (
            !inFuzzRange(_payoutDecimals, _quoteDecimals, _payoutPriceDecimals, _quotePriceDecimals)
        ) return;

        // Create market
        (uint256 id, , ) = beforeEach(
            _payoutDecimals,
            _quoteDecimals,
            _capacityInQuote,
            _payoutPriceDecimals,
            _quotePriceDecimals
        );

        // Get the maxPayout and maxAmountAccepted by the market
        (, , , , , uint256 maxPayout) = auctioneer.getMarketInfoForPurchase(id);
        uint256 maxAmountAccepted = auctioneer.maxAmountAccepted(id, referrer);

        // Calculate payout for the max amount accepted.
        uint256 payout = auctioneer.payoutFor(maxAmountAccepted, id, referrer);

        // Check that the calculated payout is equal to the max payout (use range since payout will be slightly less than maxPayout)
        assertLe(payout, maxPayout);
        assertGe(payout, maxPayout.mulDiv(999, 1000));
    }
}
