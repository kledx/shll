// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Errors} from "./Errors.sol";

/// @title CalldataDecoder — Utility for extracting selector and decoding calldata
library CalldataDecoder {
    /// @notice Extract the 4-byte function selector from calldata
    function extractSelector(bytes calldata data) internal pure returns (bytes4) {
        if (data.length < 4) revert Errors.CalldataTooShort();
        return bytes4(data[:4]);
    }

    /// @notice Decode swapExactTokensForTokens parameters
    /// @dev selector: 0x38ed1739
    /// @dev params: (uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline)
    function decodeSwap(bytes calldata data)
        internal
        pure
        returns (uint256 amountIn, uint256 amountOutMin, address[] memory path, address to, uint256 deadline)
    {
        (amountIn, amountOutMin, path, to, deadline) =
            abi.decode(data[4:], (uint256, uint256, address[], address, uint256));
    }

    /// @notice Decode approve parameters
    /// @dev selector: 0x095ea7b3
    /// @dev params: (address spender, uint256 amount)
    function decodeApprove(bytes calldata data) internal pure returns (address spender, uint256 amount) {
        (spender, amount) = abi.decode(data[4:], (address, uint256));
    }

    /// @notice Decode repayBorrowBehalf parameters
    /// @dev selector: 0x2608f818
    /// @dev params: (address borrower, uint256 repayAmount)
    function decodeRepayBorrowBehalf(bytes calldata data)
        internal
        pure
        returns (address borrower, uint256 repayAmount)
    {
        (borrower, repayAmount) = abi.decode(data[4:], (address, uint256));
    }
}
