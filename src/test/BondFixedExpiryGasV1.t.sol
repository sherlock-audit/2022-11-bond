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
import {ERC20BondToken} from "../ERC20BondToken.sol";

import {FullMath} from "../lib/FullMath.sol";

contract BondFixedExpiryGasV1Test is Test {
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

    uint8 internal constant BASE_DECIMALS = 18;
    uint8 internal constant QUOTE_DECIMALS = 18;
    int8 internal constant BASE_PRICE_DECIMALS = 0;
    int8 internal constant QUOTE_PRICE_DECIMALS = 3;
    uint256 internal bid;

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

        // Deploy token contracts
        payoutToken = new MockERC20("Payout Token", "BT", BASE_DECIMALS);
        quoteToken = new MockERC20("Quote Token", "QT", QUOTE_DECIMALS);

        // Mint tokens to users for testing
        uint256 testAmount = 1_000_000 * 10**uint8(int8(QUOTE_DECIMALS) - QUOTE_PRICE_DECIMALS);

        quoteToken.mint(alice, testAmount);
        quoteToken.mint(bob, testAmount);
        quoteToken.mint(carol, testAmount);
        payoutToken.mint(
            address(this),
            1_000_000_000 * 10**uint8(int8(BASE_DECIMALS) - BASE_PRICE_DECIMALS)
        );

        // Approve the teller for the tokens
        vm.prank(alice);
        quoteToken.approve(address(teller), testAmount);
        vm.prank(bob);
        quoteToken.approve(address(teller), testAmount);
        vm.prank(carol);
        quoteToken.approve(address(teller), testAmount);

        payoutToken.approve(
            address(teller),
            1_000_000_000 * 10**uint8(int8(BASE_DECIMALS) - BASE_PRICE_DECIMALS)
        );

        // Create market
        bid = createMarket(
            BASE_DECIMALS,
            QUOTE_DECIMALS,
            true,
            BASE_PRICE_DECIMALS,
            QUOTE_PRICE_DECIMALS
        );
    }

    function createMarket(
        uint8 _payoutDecimals,
        uint8 _quoteDecimals,
        bool _capacityInQuote,
        int8 _payoutPriceDecimals,
        int8 _quotePriceDecimals
    ) internal returns (uint256 id_) {
        uint256 capacity = _capacityInQuote
            ? 500_000 * 10**uint8(int8(_quoteDecimals) - _quotePriceDecimals)
            : 100_000 * 10**uint8(int8(_payoutDecimals) - _payoutPriceDecimals);

        int8 scaleAdjustment = int8(_payoutDecimals) -
            int8(_quoteDecimals) -
            (_payoutPriceDecimals - _quotePriceDecimals) /
            2;

        uint256 initialPrice = 5 *
            10 **
                (
                    uint8(
                        int8(36 + _quoteDecimals - _payoutDecimals) +
                            scaleAdjustment +
                            _payoutPriceDecimals -
                            _quotePriceDecimals
                    )
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
        uint32 debtBuffer = 50_000;
        uint48 vesting = uint48(block.timestamp + 14 days);
        uint48 conclusion = uint48(block.timestamp + 7 days);
        uint32 depositInterval = 24 hours;

        params = IBondSDA.MarketParams(
            payoutToken, // ERC20 payoutToken
            quoteToken, // ERC20 quoteToken
            address(0), // address callbackAddr
            _capacityInQuote, // bool capacityIn
            capacity, // uint256 capacity
            initialPrice, // uint256 initialPrice
            minimumPrice, // uint256 minimumPrice
            debtBuffer, // uint32 debtBuffer
            vesting, // uint48 vesting (timestamp or duration)
            conclusion, // uint48 conclusion (timestamp)
            depositInterval, // uint32 depositInterval (duration)
            scaleAdjustment // int8 scaleAdjustment
        );

        return auctioneer.createMarket(abi.encode(params));
    }

    function testGas_PurchaseBond() public {
        // Purchase a bond
        vm.prank(alice);
        teller.purchase(alice, referrer, bid, 5e15, 1e18);
    }

    function testGas_PurchaseAndRedeemBondToken() public {
        // Purchase a bond
        vm.prank(alice);
        (uint256 payout, uint48 expiry) = teller.purchase(alice, referrer, bid, 5e15, 1e18);

        // Set time past expiry
        vm.warp(expiry + 1);

        // Redeem the Bond Token for the underlying
        ERC20BondToken bondToken = teller.getBondTokenForMarket(bid);

        vm.prank(alice);
        teller.redeem(bondToken, payout);
    }

    function testGas_CreateMarket() public {
        // Create a market
        auctioneer.createMarket(
            abi.encode(
                IBondSDA.MarketParams(
                    payoutToken, // ERC20 payoutToken
                    quoteToken, // ERC20 quoteToken
                    address(0), // address callbackAddr
                    false, // bool capacityIn
                    100_000 * 10**18, // uint256 capacity
                    5 * 10**34, // uint256 initialPrice
                    2 * 10**34, // uint256 minimumPrice
                    uint32(50_000), // uint32 debtBuffer
                    uint48(block.timestamp + 14 days), // uint48 vesting (timestamp or duration)
                    uint48(block.timestamp + 7 days), // uint48 conclusion (timestamp)
                    24 hours, // uint32 depositInterval (duration)
                    1 // int8 scaleAdjustment
                )
            )
        );
    }
}
