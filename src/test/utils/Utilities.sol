// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {Hevm} from "./Hevm.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

//common utilities for forge tests
contract Utilities is Test {
    bytes32 internal nextUser = keccak256(abi.encodePacked("user address"));

    function getNextUserAddress() external returns (address payable) {
        //bytes32 to address conversion
        address payable user = payable(address(uint160(uint256(nextUser))));
        nextUser = keccak256(abi.encodePacked(nextUser));
        return user;
    }

    //create users with 100 ether balance
    function createUsers(uint256 userNum) external returns (address payable[] memory) {
        address payable[] memory users = new address payable[](userNum);
        for (uint256 i = 0; i < userNum; ++i) {
            address payable user = this.getNextUserAddress();
            vm.deal(user, 100 ether);
            users[i] = user;
        }
        return users;
    }

    //move block.number forward by a given number of blocks
    function mineBlocks(uint256 numBlocks) external {
        uint256 targetBlock = block.number + numBlocks;
        vm.roll(targetBlock);
    }

    // ========== UTILITIES FROM TELLER ==========
    uint256 private constant SECONDS_PER_DAY = 24 * 60 * 60;
    int256 private constant OFFSET19700101 = 2440588;

    function getNameAndSymbol(ERC20 _underlying, uint256 _expiry)
        public
        view
        returns (string memory name, string memory symbol)
    {
        // Convert expiry time to strings for name/symbol.
        (uint256 year, uint256 month, uint256 day) = timestampToDate(_expiry);
        string memory yearStr = uint2str(year);
        string memory yearStrConcat = uint2str(year % 100);
        string memory monthStr = month < 10
            ? string(abi.encodePacked(uint2str(0), uint2str(month)))
            : uint2str(month);
        string memory dayStr = day < 10
            ? string(abi.encodePacked(uint2str(0), uint2str(day)))
            : uint2str(day);

        string memory underlyingSymbol = _underlying.symbol();

        // Construct name/symbol strings.
        name = string(abi.encodePacked(underlyingSymbol, " ", monthStr, "/", dayStr, "/", yearStr));
        symbol = string(abi.encodePacked(underlyingSymbol, "-", monthStr, dayStr, yearStrConcat));
    }

    // Converts a uint256 timestamp (seconds since 1970) into human-readable year, month, and day.
    function timestampToDate(uint256 timestamp)
        public
        pure
        returns (
            uint256 year,
            uint256 month,
            uint256 day
        )
    {
        (year, month, day) = daysToDate(timestamp / SECONDS_PER_DAY);
    }

    // Some fancy math to convert a number of days into a human-readable date, courtesy of BokkyPooBah.
    // https://github.com/bokkypoobah/BokkyPooBahsDateTimeLibrary/blob/master/contracts/BokkyPooBahsDateTimeLibrary.sol
    function daysToDate(uint256 _days)
        public
        pure
        returns (
            uint256 year,
            uint256 month,
            uint256 day
        )
    {
        int256 __days = int256(_days);

        int256 num1 = __days + 68569 + OFFSET19700101;
        int256 num2 = (4 * num1) / 146097;
        num1 = num1 - (146097 * num2 + 3) / 4;
        int256 _year = (4000 * (num1 + 1)) / 1461001;
        num1 = num1 - (1461 * _year) / 4 + 31;
        int256 _month = (80 * num1) / 2447;
        int256 _day = num1 - (2447 * _month) / 80;
        num1 = _month / 11;
        _month = _month + 2 - 12 * num1;
        _year = 100 * (num2 - 49) + _year + num1;

        year = uint256(_year);
        month = uint256(_month);
        day = uint256(_day);
    }

    // Some fancy math to convert a uint into a string, courtesy of Provable Things.
    // Updated to work with solc 0.8.0.
    // https://github.com/provable-things/ethereum-api/blob/master/provableAPI_0.6.sol
    function uint2str(uint256 _i) public pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}
