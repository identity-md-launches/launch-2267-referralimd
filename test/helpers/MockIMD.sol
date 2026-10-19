// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockIMD is ERC20 {
    bool public failTransfers;
    address public callback;

    constructor() ERC20("IdentityMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailure(bool failure) external {
        failTransfers = failure;
    }

    function setCallback(address callback_) external {
        callback = callback_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!failTransfers, "IMD transfer failure");
        super._update(from, to, amount);
        if (callback != address(0) && from != address(0)) {
            (bool success,) = callback.call(abi.encodeWithSignature("onTransfer()"));
            require(success, "callback failure");
        }
    }
}
