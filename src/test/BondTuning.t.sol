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

contract BondTuningTest is Test {
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

    /* ========== HELPER FUNCTIONS ========== */
    function _findBcvTarget(BcvTargetParams memory bcvParams_) internal pure returns (uint256) {
        uint256 newBcv;
        {
            uint256 timeNeutralCapacity = bcvParams_.startCapacity.mulDiv(
                uint256(bcvParams_.length) - uint256(bcvParams_.conclusion - bcvParams_.time),
                uint256(bcvParams_.length)
            ) + bcvParams_.capacity;
            uint256 targetDebt = timeNeutralCapacity.mulDiv(
                uint256(3 days),
                uint256(bcvParams_.length)
            );
            newBcv = bcvParams_.price.mulDivUp(bcvParams_.scale, targetDebt);
        }
        for (
            uint256 t;
            t < uint256(bcvParams_.conclusion - bcvParams_.time) / 1 hours;
            t += 1 hours
        ) {
            uint256 nextTime = uint256(bcvParams_.time) + t;
            uint256 nextDebt = nextTime < uint256(bcvParams_.lastDecay)
                ? bcvParams_.totalDebt
                : (
                    nextTime - uint256(bcvParams_.lastDecay) > uint256(3 days)
                        ? 0
                        : bcvParams_.totalDebt -
                            (
                                bcvParams_.totalDebt.mulDiv(
                                    nextTime - uint256(bcvParams_.lastDecay),
                                    uint256(3 days)
                                )
                            )
                );
            uint256 nextPrice = newBcv.mulDiv(nextDebt, bcvParams_.scale);
            uint256 nextTimeNeutralCapacity = bcvParams_.startCapacity.mulDiv(
                uint256(bcvParams_.length) - (uint256(bcvParams_.conclusion) - nextTime),
                uint256(bcvParams_.length)
            ) + bcvParams_.capacity;
            uint256 nextTargetDebt = nextTimeNeutralCapacity.mulDiv(3 days, bcvParams_.length);
            uint256 nextBcv = nextPrice.mulDivUp(bcvParams_.scale, nextTargetDebt);
            if (nextBcv < newBcv) break;
            newBcv = nextBcv;
        }

        return newBcv;
    }

    /* ========== TESTS ========== */
    struct BcvTargetParams {
        uint48 time;
        uint48 conclusion;
        uint48 length;
        uint48 lastDecay;
        uint256 startCapacity;
        uint256 capacity;
        uint256 totalDebt;
        uint256 scale;
        uint256 price;
    }

    function testCorrectness_TuningUpManipulationAvoided() public {
        // Setup global variables for attack
        bool attacked;
        bool adjusted;
        // uint256 regularTarget = 10000 - 500; // 5% discount
        // uint256 marketPrice = 5e18;
        uint48 time = uint48(block.timestamp);

        // Create market
        (uint256 id, uint256 scale, uint256 price) = beforeEach(
            2 hours, // deposit interval => decayInterval = 3 days (minimum)
            7 days // duration
        );

        // Manually set the tune interval to a low value to simulate worst case
        // Cannot be less than deposit interval
        auctioneer.setIntervals(id, [uint32(2 hours), uint32(1 hours), uint32(3 days)]);

        // Get static market data for use in calculations
        (, , , , , uint256 startCapacity, , , , , , ) = auctioneer.markets(id);
        (, , , uint48 conclusion) = auctioneer.terms(id);
        (, , uint32 length, , uint32 tuneInterval, , , , , ) = auctioneer.metadata(id);
        /// Using 3 days for debt decay interval since we know it will be the minimum to avoid stack too deep

        // Walk through time and attempt to execute tuning manipulation attack
        while (auctioneer.isLive(id)) {
            price = auctioneer.marketPrice(id);
            if (attacked) {
                console2.log("Current Price:", price);
            } else {
                BcvTargetParams memory bcvParams;
                uint48 lastTune;
                {
                    (, , , , , uint256 capacity, uint256 totalDebt, , , , , ) = auctioneer.markets(
                        id
                    );
                    if (capacity < startCapacity.mulDiv(1, 100)) break;
                    (uint48 lastTuneIn, uint48 lastDecay, , , , , , , , ) = auctioneer.metadata(id);
                    lastTune = lastTuneIn;

                    bcvParams = BcvTargetParams(
                        time,
                        conclusion,
                        uint48(length),
                        lastDecay,
                        startCapacity,
                        capacity,
                        totalDebt,
                        scale,
                        price
                    );
                }
                if (lastTune + tuneInterval < time) {
                    // Calculate a target BCV
                    auctioneer.getTeller();
                    uint256 newBcv = _findBcvTarget(bcvParams);

                    // Time to discount is the amount of time required for the market to decay debt to reach the target discount with the new bcv
                    // 475e34 is 95% of starting price 5e18, which we assume is static. 5% discount is chosen as what a regular user would bond.
                    uint48 timeToDiscount = bcvParams.lastDecay +
                        uint48(
                            uint256(3 days).mulDiv(uint256(475e34), newBcv).mulDiv(
                                scale,
                                bcvParams.totalDebt
                            )
                        ) >
                        uint48(3 days)
                        ? 0
                        : uint48(3 days) -
                            uint48(
                                uint256(3 days).mulDiv(uint256(475e34), newBcv).mulDiv(
                                    scale,
                                    bcvParams.totalDebt
                                )
                            );
                    if (time >= (conclusion - tuneInterval)) {
                        // Final ping to trigger adjustment for discount
                        console2.log("Final ping to trigger adjustment for discount");
                        vm.prank(alice);
                        teller.purchase(alice, referrer, id, uint256(5), uint256(0));
                        attacked = true;
                    } else if (timeToDiscount <= (conclusion - tuneInterval * 2) && !adjusted) {
                        // Drive BCV up
                        console2.log("Ping to drive BCV up");
                        (uint256 prevBcv, , , ) = auctioneer.terms(id);
                        vm.prank(alice);
                        teller.purchase(alice, referrer, id, uint256(5), uint256(0));
                        (uint256 bcv, , , ) = auctioneer.terms(id);
                        if (bcv == prevBcv) adjusted = true;
                    }
                }
                auctioneer.getTeller();
                // Regular users purchase bonds at 5% discount for 1/3 of max bond size
                if (price < uint256(475e34)) {
                    uint256 bondAmount = auctioneer.maxAmountAccepted(id, referrer) / 2;
                    console2.log("Regular user purchase price", price);
                    vm.prank(bob);
                    teller.purchase(bob, referrer, id, bondAmount, uint256(0));
                }
            }

            time += 600;
            vm.warp(time);
        }

        price = auctioneer.marketPrice(id);
        console2.log("Final Price", price);
        console2.log(
            "Discount from market price:",
            price > uint256(5e36) ? 0 : 100 - price.mulDiv(100, 5e36)
        );
        console2.log(
            "Premium over market price",
            price > uint256(5e36) ? price.mulDiv(100, 5e36) - 100 : 0
        );
        console2.log(
            "% of Capacity remaining:",
            auctioneer.currentCapacity(id).mulDiv(100, startCapacity)
        );

        assertGt(price, uint256(475e34));
        assertLt(auctioneer.currentCapacity(id), startCapacity.mulDiv(5, 100));
    }
}
