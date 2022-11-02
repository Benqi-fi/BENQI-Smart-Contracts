// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IVeERC20.sol";

/**
 * @dev Interface of the VeQi
 */
interface IVeQi is IVeERC20 {
    function isUser(address _addr) external view returns (bool);

    function deposit(uint256 _amount) external;

    function claim() external;

    function withdraw(uint256 _amount) external;

    function getStakedQi(address _addr) external view returns (uint256);

    function eventualTotalSupply() external view returns (uint256);

    function eventualBalanceOf(address account) external view returns (uint256);
}