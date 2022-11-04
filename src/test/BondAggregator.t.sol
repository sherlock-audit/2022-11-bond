// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {Utilities} from "./utils/Utilities.sol";
import {console2} from "forge-std/console2.sol";

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {RolesAuthority, Authority} from "solmate/auth/authorities/RolesAuthority.sol";
import {MockFOTERC20} from "./utils/mocks/MockFOTERC20.sol";

import {IBondSDA} from "../interfaces/IBondSDA.sol";
import {IBondCallback} from "../interfaces/IBondCallback.sol";
import {IBondAuctioneer} from "../interfaces/IBondAuctioneer.sol";

import {BondFixedExpirySDA} from "../BondFixedExpirySDA.sol";
import {BondFixedExpiryTeller} from "../BondFixedExpiryTeller.sol";
import {BondAggregator} from "../BondAggregator.sol";
import {ERC20BondToken} from "../ERC20BondToken.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {FullMath} from "../lib/FullMath.sol";

contract BondAggregatorTest is Test {
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
    BondFixedExpirySDA internal auctioneer;
    BondFixedExpiryTeller internal teller;
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
        teller = new BondFixedExpiryTeller(policy, aggregator, guardian, auth);
        auctioneer = new BondFixedExpirySDA(teller, aggregator, guardian, auth);

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
        uint48 vesting = uint48(block.timestamp + 14 days); // fixed expiry in 14 days
        uint48 conclusion = uint48(block.timestamp + 7 days);
        uint32 depositInterval = 24 hours;

        params = IBondSDA.MarketParams(
            payoutToken, // ERC20 payoutToken
            quoteToken, // ERC20 quoteToken
            address(0), // address callbackAddr - No callback for V1
            _capacityInQuote, // bool capacityIn
            capacity, // uint256 capacity
            price, // uint256 initialPrice
            minimumPrice, // uint256 minimumPrice
            debtBuffer, // uint32 debtBuffer
            vesting, // uint48 vesting (timestamp or duration)
            conclusion, // uint48 conclusion (timestamp)
            depositInterval, // uint48 depositInterval (duration)
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
        uint256 testAmount = 1_000_000 * 10**uint8(int8(_quoteDecimals) - _quotePriceDecimals);

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

        // Approve the teller with this contract for payouts
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

    // ========== PERMISSIONED FUNCTIONS ========== //
    // TODO
    // [X] registerAuctioneer
    //      [X] auctioneer added to whitelist
    //      [X] only callable by guardian
    //      [X] only register auctioneer once
    // [ ] registerMarket
    //      [ ] market ID registered and incremented for next market
    //      [ ] only callable by whitelisted auctioneer
    //      [ ] market tokens cannot be zero address

    function testCorrectness_AuctioneerAddedToWhitelist() public {
        // Register a new auctioneer and expect it to be added to the whitelist
        vm.prank(guardian);
        aggregator.registerAuctioneer(IBondAuctioneer(bob));
        assertEq(address(aggregator.auctioneers(1)), bob);
        // TODO determine if `_whitelist` should be made public instead of internal
    }

    function testCorrectness_CannotRegisterAuctioneerTwice() public {
        // Try to register an already registered auctioneer
        bytes memory err = abi.encodeWithSignature(
            "Aggregator_AlreadyRegistered(address)",
            address(auctioneer)
        );
        vm.prank(guardian);
        vm.expectRevert(err);
        aggregator.registerAuctioneer(auctioneer);
    }

    function testCorrectness_OnlyGuardianCanRegisterAuctioneer() public {
        // Call with non-guardian and expect revert
        bytes memory err = abi.encodePacked("UNAUTHORIZED");
        vm.prank(alice);
        vm.expectRevert(err);
        aggregator.registerAuctioneer(IBondAuctioneer(bob));
    }

    function testCorrectness_RegisterMarket() public {
        // Create a market prior to testing so the marketId and tokens are not zero
        beforeEach(18, 18, true, 0, 0);

        // Store initial market counter
        uint256 initialMarketCounter = aggregator.marketCounter();

        // Register a new market with the whitelisted auctioneer
        vm.prank(address(auctioneer));
        uint256 marketId = aggregator.registerMarket(payoutToken, quoteToken);
        assertEq(marketId, initialMarketCounter);

        // Check that the aggregator storage variables have been updated correctly
        assertEq(aggregator.marketCounter(), initialMarketCounter + 1);
        assertEq(address(aggregator.marketsToAuctioneers(marketId)), address(auctioneer));
        assertEq(aggregator.marketsForPayout(address(payoutToken), 1), marketId);
        assertEq(aggregator.marketsForQuote(address(quoteToken), 1), marketId);
    }

    function testCorrectness_OnlyWhitelistedCanRegisterMarket() public {
        // Create a market prior to testing so the marketId and tokens are not zero
        beforeEach(18, 18, true, 0, 0);

        // Call with non-whitelisted auctioneer and expect revert
        bytes memory err = abi.encodeWithSignature("Aggregator_OnlyAuctioneer()");
        vm.prank(alice);
        vm.expectRevert(err);
        aggregator.registerMarket(payoutToken, quoteToken);
    }

    function testCorrectness_RegisterMarketTokensNotZero() public {
        // Create a market prior to testing so the marketId and tokens are not zero
        beforeEach(18, 18, true, 0, 0);

        // Call with zero address for payout token and expect revert
        bytes memory err = abi.encodeWithSignature("Aggregator_InvalidParams()");
        vm.prank(address(auctioneer));
        vm.expectRevert(err);
        aggregator.registerMarket(ERC20(address(0)), quoteToken);

        // Call with zero address for quote token and expect revert
        vm.prank(address(auctioneer));
        vm.expectRevert(err);
        aggregator.registerMarket(payoutToken, ERC20(address(0)));

        // Call with zero address for both tokens and expect revert
        vm.prank(address(auctioneer));
        vm.expectRevert(err);
        aggregator.registerMarket(ERC20(address(0)), ERC20(address(0)));
    }
}
