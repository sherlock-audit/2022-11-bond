# Bond Protocol contest details

- 33,333 USDC main award pot
- Join [Sherlock Discord](https://discord.gg/MABEWyASkp)
- Submit findings using the issue page in your private contest repo (label issues as med or high)
- [Read for more details](https://docs.sherlock.xyz/audits/watsons)
- Starts November 7, 2022 15:00 UTC
- Ends November 16, 2022 15:00 UTC

# Resources

- [Docs](https://docs.bondprotocol.finance/)
- [SDAM Paper](https://github.com/Bond-Protocol/research/blob/master/papers/Sequential_Dutch_Auction_Markets.pdf) (note: the implementation section is not up to date with the latest code, but the math section should be accurate).
- [Twitter](https://twitter.com/bond_protocol)

# On-chain context

TO FILL IN BY PROTOCOL

```
DEPLOYMENT: [e.g. mainnet, arbitrum, optimism, ..]
ERC20: [e.g. any, none, USDC, USDC and USDT]
ERC721: [e.g. any, none, UNI-V3]
```

# Audit scope

The following contracts in this repository are in scope:
- bases
    - BondBaseCallback.sol
    - BondBaseSDA.sol
    - BondBaseTeller.sol
- interfaces
    - IBondAggregator.sol
    - IBondAuctioneer.sol
    - IBondCallback.sol
    - IBondFixedExpiryTeller.sol
    - IBondFixedTermTeller.sol
    - IBondSDA.sol
    - IBondTeller.sol
- BondAggregator.sol
- BondFixedExpirySDA.sol
- BondFixedExpiryTeller.sol
- BondFixedTermSDA.sol
- BondFixedTermTeller.sol
- BondSampleCallback.sol
- ERC20BondToken.sol

# About Bond Protocol

Bond Protocol is a permissionless system to create Olympus-style bond markets for any token pair. The markets do not require maintenance and will manage bond prices based on activity. Bond issuers create BondMarkets that pay out a Payout Token in exchange for deposited Quote Tokens. Users can purchase future-dated Payout Tokens with Quote Tokens at the current market price and receive Bond Tokens to represent their position while their bond vests. Once the Bond Tokens vest, they can redeem it for the Quote Tokens.

The Bond system is designed to be extensible where additional Auctioneers (with different pricing algorithms) or Tellers (with different payout mechanics) can be built and incorporated into the existing design.

# Getting Started

This repository uses Foundry as its development and testing environment. You must first [install Foundry](https://getfoundry.sh/) to build the contracts and run the test suite.

## Clone the repository into a local directory

```sh
$ mkdir bonds
$ git clone https://github.com/sherlock-audit/2022-11-bond.git ./bonds
```

## Install dependencies

```sh
$ cd bonds
$ forge build # installs git submodule dependencies when contracts are compiled
```

## Build

Compile the contracts with `forge build`.

## Tests

Run the full test suite with `forge test`.

Fuzz tests have been written to cover a range of market situations. Default number of runs is 4096, although there are 2^33 possible param combinations.

The test suite can take awhile to run, specifically the `BondDebt.t.sol` file. To run the test suite without this file: `forge test --no-match-contract BondDebtTest`

