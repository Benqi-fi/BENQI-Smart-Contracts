// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";


interface IStakedAvax is IERC20Upgradeable {
    function getSharesByPooledAvax(uint avaxAmount) external view returns (uint);
    function getPooledAvaxByShares(uint shareAmount) external view returns (uint);
    function submit() external payable returns (uint);
}
