// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {Utilities} from "./utils/Utilities.sol";
import {console2} from "forge-std/console2.sol";

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {RolesAuthority, Authority} from "solmate/auth/authorities/RolesAuthority.sol";
import {MockBondCallback} from "./utils/mocks/MockBondCallback.sol";

import {IBondSDA} from "../interfaces/IBondSDA.sol";
import {IBondCallback} from "../interfaces/IBondCallback.sol";

import {BondFixedExpirySDA} from "../BondFixedExpirySDA.sol";
import {BondFixedExpiryTeller} from "../BondFixedExpiryTeller.sol";
import {BondAggregator} from "../BondAggregator.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {FullMath} from "../lib/FullMath.sol";

contract BondEmissionsTest is Test {
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
        teller = new BondFixedExpiryTeller(treasury, aggregator, guardian, auth);
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

        // Set referrer fee
        vm.prank(referrer);
        teller.setReferrerFee(uint48(200));
    }

    function createMarket(uint32 _depositInterval, uint48 _duration)
        internal
        returns (
            uint256 id,
            uint256 scale,
            uint256 price
        )
    {
        uint256 capacity = 100_000 * 1e18;

        int8 scaleAdjustment = 0;

        scale = 10**uint8(36 + scaleAdjustment);

        price = 5 * 1e36;

        uint256 minimumPrice = 2 * 1e36;
        uint32 debtBuffer = 50_000;
        uint48 vesting = uint48(block.timestamp + 90 days); // fixed expiry in 90 days
        uint48 conclusion = uint48(block.timestamp) + _duration;
        uint32 depositInterval = _depositInterval;

        params = IBondSDA.MarketParams(
            payoutToken, // ERC20 payoutToken
            quoteToken, // ERC20 quoteToken
            address(callback), // address callbackAddr
            false, // bool capacityInQuote
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

    function beforeEach(uint32 _depositInterval, uint48 _duration)
        internal
        returns (
            uint256 id,
            uint256 scale,
            uint256 price
        )
    {
        // Deploy token and callback contracts
        payoutToken = new MockERC20("Payout Token", "BT", 18);
        quoteToken = new MockERC20("Quote Token", "QT", 18);
        callback = new MockBondCallback(payoutToken);

        // Mint tokens to users for testing
        {
            uint256 testAmount = 1_000_000 * 1e18;

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
        }

        // Create market
        (id, scale, price) = createMarket(_depositInterval, _duration);

        // Update intervals to turn off tuning
        uint32[3] memory intervals = [
            uint32(_duration * 2),
            uint32(_duration * 2),
            (_depositInterval * 5 > uint32(3 days)) ? _depositInterval * 5 : uint32(3 days)
        ];

        auctioneer.setIntervals(id, intervals);
    }

    // function testCorrectness_EmSpeedStandardFuzz(uint256 bondAmount) public {
    //     // Limit fuzz range to reasonable values
    //     {
    //         uint256 maxBond = uint256(500000 * 1e18) / 15;
    //         uint256 minBond = 5000e18;
    //         if (bondAmount > maxBond || bondAmount < minBond) return;
    //     }
    //     // Create market
    //     (uint256 id, uint256 scale, uint256 price) = beforeEach(24 hours, 14 days);

    //     (, , , uint48 conclusion) = auctioneer.terms(id);
    //     (, , , , , uint256 capacity, , , , , , ) = auctioneer.markets(id);
    //     uint256 minAmountOut = bondAmount.mulDiv(scale / 2, price);

    //     uint48 time = uint48(block.timestamp);
    //     uint256 startCapacity = capacity;
    //     uint256 currentPrice;
    //     uint256 expectedPayout;
    //     while (time < conclusion && capacity > 0) {
    //         // Purchase a bond if price is at or under market
    //         currentPrice = auctioneer.marketPrice(id);
    //         expectedPayout = bondAmount.mulDiv((scale * 1011) / 1000, currentPrice);
    //         if (expectedPayout > capacity) {
    //             bondAmount = capacity.mulDiv(currentPrice, (scale * 1011) / 1000);
    //             minAmountOut = bondAmount.mulDiv(scale / 2, price);
    //         }
    //         if (currentPrice <= price) {
    //             vm.prank(alice);
    //             teller.purchase(alice, referrer referrer, id, bondAmount, minAmountOut);
    //         }

    //         // Get updated capacity
    //         (, , , , , capacity, , , , , , ) = auctioneer.markets(id);

    //         // Increment time
    //         time += 600;
    //         vm.warp(time);
    //     }

    //     uint48 marketEnded = time;

    //     assertGt(marketEnded, (conclusion * 95) / 100);
    //     assertLt(capacity, (startCapacity * 5) / 100);
    // }

    function testCorrectness_EmSpeedLongHighAmount() public {
        // Create market
        (uint256 id, uint256 scale, uint256 price) = beforeEach(
            36 hours, // deposit interval = 1.5 days => decayInterval = 7.5 days
            30 days // duration = 30 days
        );

        // Set bond amount close to max bond
        uint256 bondAmount = auctioneer.maxAmountAccepted(id, referrer);

        (, , , uint48 conclusion) = auctioneer.terms(id);
        (, , , , , uint256 capacity, , , , , , ) = auctioneer.markets(id);
        uint256 minAmountOut = bondAmount.mulDiv(scale / 2, price);

        uint48 time = uint48(block.timestamp);
        uint256 startCapacity = capacity;
        uint256 threshold = capacity.mulDiv(1, 10000);
        uint256 currentPrice;
        while (time < conclusion && capacity > threshold) {
            // Purchase a bond if price is at or under market
            bondAmount = auctioneer.maxAmountAccepted(id, referrer);
            currentPrice = auctioneer.marketPrice(id);
            minAmountOut = bondAmount.mulDiv(scale / 2, currentPrice);
            if (currentPrice <= price) {
                vm.prank(alice);
                teller.purchase(alice, referrer, id, bondAmount, minAmountOut);
            }

            // Get updated capacity
            (, , , , , capacity, , , , , , ) = auctioneer.markets(id);

            // Increment time
            time += 600;
            vm.warp(time);
        }

        uint48 marketEnded = time;
        console2.log("Long decay interval, high bond amount");
        console2.log("Ended at % of duration:");
        console2.log(((marketEnded - (conclusion - 30 days)) * 100) / 30 days);
        console2.log("Capacity % left at end: ");
        console2.log((capacity * 100) / startCapacity);

        assertGt(marketEnded - (conclusion - 30 days), (30 days * 95) / 100);
        assertLt(capacity, (startCapacity * 5) / 100);
    }

    function testCorrectness_EmSpeedLongLowAmount() public {
        // Create market
        (uint256 id, uint256 scale, uint256 price) = beforeEach(
            36 hours, // deposit interval = 1.5 days => decayInterval = 7.5 days
            30 days // duration = 30 days
        );

        // Set bond amount to a low value relative to max bond
        uint256 bondAmount = auctioneer.maxAmountAccepted(id, referrer).mulDiv(5, 100);

        (, , , uint48 conclusion) = auctioneer.terms(id);
        (, , , , , uint256 capacity, , , , , , ) = auctioneer.markets(id);
        uint256 minAmountOut = bondAmount.mulDiv(scale / 2, price);

        uint48 time = uint48(block.timestamp);
        uint256 startCapacity = capacity;
        uint256 threshold = capacity.mulDiv(1, 10000);
        uint256 currentPrice;
        // uint256 expectedPayout;
        while (time < conclusion && capacity > threshold) {
            // Purchase a bond if price is at or under market
            bondAmount = auctioneer.maxAmountAccepted(id, referrer).mulDiv(5, 100);
            currentPrice = auctioneer.marketPrice(id);
            minAmountOut = bondAmount.mulDiv(scale / 2, currentPrice);
            if (currentPrice <= price) {
                vm.prank(alice);
                teller.purchase(alice, referrer, id, bondAmount, minAmountOut);
            }

            // Get updated capacity
            (, , , , , capacity, , , , , , ) = auctioneer.markets(id);

            // Increment time
            time += 600;
            vm.warp(time);
        }

        uint48 marketEnded = time;
        console2.log("Long decay interval, low bond amount");
        console2.log("Ended at % of duration:");
        console2.log(((marketEnded - (conclusion - 30 days)) * 100) / 30 days);
        console2.log("Capacity % left at end: ");
        console2.log((capacity * 100) / startCapacity);

        assertGt(marketEnded - (conclusion - 30 days), (30 days * 95) / 100);
        assertLt(capacity, (startCapacity * 5) / 100);
    }

    function testCorrectness_EmSpeedShortHighAmount() public {
        // Create market
        (uint256 id, uint256 scale, uint256 price) = beforeEach(
            4 hours, // depositInterval => decayInterval = 3 days (min)
            30 days // duration = 30 days
        );

        // Set bond amount close to max bond
        uint256 bondAmount = auctioneer.maxAmountAccepted(id, referrer);

        (, , , uint48 conclusion) = auctioneer.terms(id);
        (, , , , , uint256 capacity, , , , , , ) = auctioneer.markets(id);
        uint256 minAmountOut = bondAmount.mulDiv(scale / 2, price);

        uint48 time = uint48(block.timestamp);
        uint256 startCapacity = capacity;
        uint256 threshold = capacity.mulDiv(1, 10000);
        uint256 currentPrice;
        while (time < conclusion && capacity > threshold) {
            // Purchase a bond if price is at or under market
            bondAmount = auctioneer.maxAmountAccepted(id, referrer);
            currentPrice = auctioneer.marketPrice(id);
            minAmountOut = bondAmount.mulDiv(scale / 2, currentPrice);
            if (currentPrice <= price) {
                vm.prank(alice);
                teller.purchase(alice, referrer, id, bondAmount, minAmountOut);
            }

            // Get updated capacity
            (, , , , , capacity, , , , , , ) = auctioneer.markets(id);

            // Increment time
            time += 600;
            vm.warp(time);
        }

        uint48 marketEnded = time;
        console2.log("Min decay interval, high bond amount");
        console2.log("Ended at % of duration:");
        console2.log(((marketEnded - (conclusion - 30 days)) * 100) / 30 days);
        console2.log("Capacity % left at end: ");
        console2.log((capacity * 100) / startCapacity);

        assertGt(marketEnded - (conclusion - 30 days), (30 days * 95) / 100);
        assertLt(capacity, (startCapacity * 5) / 100);
    }

    function testCorrectness_EmSpeedShortLowAmount() public {
        // Create market
        (uint256 id, uint256 scale, uint256 price) = beforeEach(
            4 hours, // depositInterval => decayInterval = 3 days (min)
            30 days // duration = 30 days
        );

        // Set bond amount low relative to max bond
        uint256 bondAmount = auctioneer.maxAmountAccepted(id, referrer).mulDiv(5, 100);

        (, , , uint48 conclusion) = auctioneer.terms(id);
        (, , , , , uint256 capacity, , , , , , ) = auctioneer.markets(id);
        uint256 minAmountOut = bondAmount.mulDiv(scale / 2, price);

        uint48 time = uint48(block.timestamp);
        uint256 startCapacity = capacity;
        uint256 threshold = capacity.mulDiv(1, 10000);
        uint256 currentPrice;
        while (time < conclusion && capacity > threshold) {
            // Purchase a bond if price is at or under market
            bondAmount = auctioneer.maxAmountAccepted(id, referrer).mulDiv(5, 100);
            currentPrice = auctioneer.marketPrice(id);
            minAmountOut = bondAmount.mulDiv(scale / 2, currentPrice);
            if (currentPrice <= price) {
                vm.prank(alice);
                teller.purchase(alice, referrer, id, bondAmount, minAmountOut);
            }

            // Get updated capacity
            (, , , , , capacity, , , , , , ) = auctioneer.markets(id);

            // Increment time
            time += 600;
            vm.warp(time);
        }

        uint48 marketEnded = time;
        console2.log("Min decay interval, low bond amount");
        console2.log("Ended at % of duration:");
        console2.log(((marketEnded - (conclusion - 30 days)) * 100) / 30 days);
        console2.log("Capacity % left at end: ");
        console2.log((capacity * 100) / startCapacity);

        assertGt(marketEnded - (conclusion - 30 days), (30 days * 95) / 100);
        assertLt(capacity, (startCapacity * 5) / 100);
    }
}
