// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @dev Interface of the GaugeController
 */
interface IGaugeController {
    function getNodesRange(uint256 _from, uint256 _to) external view returns (string[] memory);
    function getNodesLength() external view returns (uint256);
    function getNodeUsersRange(string memory _nodeId, uint256 _from, uint256 _to) external view returns (address[] memory);
    function getNodeUsersLength(string memory _nodeId) external view returns (uint256);
    function getVotesRange(uint256 _from, uint256 _to) external view returns (string[] memory, uint256[] memory);
    function getVotesForNode(string memory _nodeId) external view returns (uint256);
    function voteNodes(string[] memory _nodeIds, uint256[] memory _weights) external;
    function voteNode(string memory _nodeId, uint256 _weight) external;
    function unvoteNodes(string[] memory _nodeIds, uint256[] memory _weights) external;
    function unvoteNode(string memory _nodeId, uint256 _weight) external;
    function getUserVotesLength() external view returns (uint256);
    function getUserVotesRange(uint256 _from, uint256 _to) external view returns (string[] memory, uint256[] memory);
}
