// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IGaugeController.sol";
import "./interfaces/IVeQi.sol";

/// @title GaugeController
/// @notice controls allocation gauges for liquid staking delegation
contract GaugeController is IGaugeController, Initializable, OwnableUpgradeable {

    /// @notice veQi contract
    IVeQi public veQi;

    /// @notice cumulative weight that has been allocated (in bips)
    mapping(address => uint256) public userVotedWeight;

    /// @notice nodes that a user has voted
    mapping(address => string[]) public userVotedNodes;

    /// @notice user node array lookup map
    mapping(address => mapping(string => uint256)) public userVotedNodesIndexes;

    /// @notice cumulative weight that has been allocated to a node by user (in bips)
    mapping(string => mapping(address => uint256)) public nodeUserVotedWeight;

    /// @notice users who voted for a node
    mapping(string => address[]) public nodeUsers;
    mapping(string => mapping(address => uint256)) public nodeUsersIndex;

    /// @notice nodes with vote
    string[] public nodes;
    mapping(string => uint256) public nodesIndex;

    event VoteNode(address indexed user, string nodeId, uint256 weight);
    event UnvoteNode(address indexed user, string nodeId, uint256 weight);

    function initialize(IVeQi _veQi) public initializer {
        require(address(_veQi) != address(0), "zero address");

        __Ownable_init();

        veQi = _veQi;
    }

    /// @notice votes for validator nodes
    /// @param _nodeIds list of node ids
    /// @param _weights list of weights in bips
    function voteNodes(string[] calldata _nodeIds, uint256[] calldata _weights) external override {
        require(_nodeIds.length == _weights.length, "nodeIds and weights array length mismatch");

        uint256 length = _nodeIds.length;
        for (uint256 i; i < length;) {
            voteNode(_nodeIds[i], _weights[i]);
            unchecked { ++i; }
        }
    }

    /// @notice votes for a validator node
    /// @param _nodeId node id
    /// @param _weight weight in bips
    function voteNode(string calldata _nodeId, uint256 _weight) public override {
        uint256 newTotalWeight = userVotedWeight[msg.sender] + _weight;

        require(_weight > 0, "zero vote");
        require(newTotalWeight <= 10000, "exceeded all available weight");

        userVotedWeight[msg.sender] = newTotalWeight;

        if (nodeUsers[_nodeId].length == 0) {
            nodesIndex[_nodeId] = nodes.length;
            nodes.push(_nodeId);
        }

        if (nodeUserVotedWeight[_nodeId][msg.sender] == 0) {
            nodeUsersIndex[_nodeId][msg.sender] = nodeUsers[_nodeId].length;
            nodeUsers[_nodeId].push(msg.sender);

            userVotedNodesIndexes[msg.sender][_nodeId] = userVotedNodes[msg.sender].length;
            userVotedNodes[msg.sender].push(_nodeId);
        }

        unchecked {
            nodeUserVotedWeight[_nodeId][msg.sender] = nodeUserVotedWeight[_nodeId][msg.sender] + _weight;
        }

        emit VoteNode(msg.sender, _nodeId, _weight);
    }

    /// @notice unvotes for validator nodes
    /// @param _nodeIds list of node ids
    /// @param _weights list of weights in bips
    function unvoteNodes(string[] calldata _nodeIds, uint256[] calldata _weights) external override {
        require(_nodeIds.length == _weights.length, "nodeIds and weights array length mismatch");

        uint256 length = _nodeIds.length;
        for (uint256 i; i < length;) {
            unvoteNode(_nodeIds[i], _weights[i]);
            unchecked { ++i; }
        }
    }

    /// @notice unvotes for a validator node
    /// @param _weight weight in bips
    function unvoteNode(string calldata _nodeId, uint256 _weight) public override {
        uint256 newTotalWeight = userVotedWeight[msg.sender] - _weight;
        uint256 newNodeWeight = nodeUserVotedWeight[_nodeId][msg.sender] - _weight;

        require(_weight > 0, "zero weight");
        require(newTotalWeight >= 0, "exceeded all voted weight");
        require(newNodeWeight >= 0, "exceeded node voted weight");

        userVotedWeight[msg.sender] = newTotalWeight;
        nodeUserVotedWeight[_nodeId][msg.sender] = newNodeWeight;

        if (nodeUserVotedWeight[_nodeId][msg.sender] == 0) {
            removeUserFromNodeUsers(_nodeId, msg.sender);

            if (nodeUsers[_nodeId].length == 0) {
                removeNodeFromNodes(_nodeId);
                delete nodeUsers[_nodeId];
            }

            uint256 index = userVotedNodesIndexes[msg.sender][_nodeId];
            string memory lastVotedNode = userVotedNodes[msg.sender][userVotedNodes[msg.sender].length - 1];
            userVotedNodes[msg.sender][index] = lastVotedNode;
            userVotedNodesIndexes[msg.sender][lastVotedNode] = index;

            delete userVotedNodesIndexes[msg.sender][_nodeId];
            userVotedNodes[msg.sender].pop();
        }

        emit UnvoteNode(msg.sender, _nodeId, _weight);
    }

    /// @notice removes a node from the node list
    /// @param _nodeId node to remove from list
    function removeNodeFromNodes(string calldata _nodeId) private {
        uint256 index = nodesIndex[_nodeId];

        require(keccak256(abi.encodePacked(nodes[index])) == keccak256(abi.encodePacked(_nodeId)), "incorrect removal of node from list");

        string memory last = nodes[nodes.length - 1];
        nodes[index] = last;
        nodesIndex[last] = index;

        nodes.pop();
        delete nodesIndex[_nodeId];
    }

    /// @notice removes a user from the node user list
    /// @param _user user to remove from list
    function removeUserFromNodeUsers(string calldata _nodeId, address _user) private {
        address[] storage users = nodeUsers[_nodeId];
        uint256 index = nodeUsersIndex[_nodeId][_user];

        require(users[index] == _user, "incorrect removal of user from list");

        address last = users[users.length - 1];
        users[index] = last;
        nodeUsersIndex[_nodeId][last] = index;

        users.pop();
        delete nodeUsersIndex[_nodeId][_user];
    }

    /// @notice retrieves all nodes within a range
    /// @param _from start index (starts from 0)
    /// @param _to end index (inclusive)
    function getNodesRange(uint256 _from, uint256 _to) external view override returns (string[] memory) {
        require(_from <= _to, "from index must be lesser/equal to index");
        require(_to < nodes.length, "to index exceeds total nodes");

        unchecked {
            uint256 size = _to - _from + 1;
            string[] memory nodeList = new string[](size);

            for (uint256 i = 0; i < size; ++i) {
                nodeList[i] = nodes[_from + i];
            }

            return nodeList;
        }
    }

    /// @notice retrieves number of nodes
    function getNodesLength() external view override returns (uint256) {
        return nodes.length;
    }

    /// @notice retrieves all users for a node within a range
    /// @param _from start index (starts from 0)
    /// @param _to end index (inclusive)
    function getNodeUsersRange(string memory _nodeId, uint256 _from, uint256 _to) external view override returns (address[] memory) {
        require(_from <= _to, "from index must be lesser/equal to index");
        require(_to < nodes.length, "to index exceeds total nodes");

        unchecked {
            uint256 size = _to - _from + 1;
            address[] memory userList = new address[](size);
            address[] storage allNodeUsers = nodeUsers[_nodeId];

            for (uint256 i = 0; i < size; ++i) {
                userList[i] = allNodeUsers[_from + i];
            }

            return userList;
        }
    }

    /// @notice retrieves number of users for a node
    function getNodeUsersLength(string calldata _nodeId) external view override returns (uint256) {
        return nodeUsers[_nodeId].length;
    }

    /// @notice retrieves votes over a range of nodes (includes pending veQI)
    /// @param _from start index (starts from 0)
    /// @param _to end index (inclusive)
    function getVotesRange(uint256 _from, uint256 _to) external view override returns (string[] memory, uint256[] memory) {
        require(_from <= _to, "from index must be lesser/equal to index");
        require(_to < nodes.length, "to index exceeds total nodes");

        unchecked {
            uint256 size = _to - _from + 1;
            string[] memory nodeList = new string[](size);
            uint256[] memory voteList = new uint256[](size);

            for (uint256 i; i < size; ++i) {
                uint256 nodeIndex = _from + i;
                nodeList[i] = nodes[nodeIndex];
                voteList[i] = getVotesForNode(nodes[nodeIndex]);
            }

            return (nodeList, voteList);
        }
    }

    /// @notice retrieves votes for a node (includes pending veQI)
    function getVotesForNode(string memory _nodeId) public view override returns (uint256) {
        address[] memory users = nodeUsers[_nodeId];
        uint256 nodeVotes;

        uint256 length = users.length;
        for (uint256 i; i < length;) {
            address user = users[i];

            if (veQi.getStakedQi(user) != 0) {
                uint256 userWeight = nodeUserVotedWeight[_nodeId][user];
                uint256 userVotes = userWeight * veQi.eventualBalanceOf(user) / 10_000;
                nodeVotes = nodeVotes + userVotes;
            }

            unchecked { ++i; }
        }

        return nodeVotes;
    }

    /// @notice get the number of nodes the user has voted for
    function getUserVotesLength() external view override returns (uint256) {
       return userVotedNodes[msg.sender].length;
    }

    /// @notice get a paginated list of nodes and their votes the user has voted for
    function getUserVotesRange(uint256 _from, uint256 _to) external view override returns (string[] memory, uint256[] memory) {
        require(_from <= _to, "from index must be lesser/equal to to index");
        require(_to < userVotedNodes[msg.sender].length, "to index exceeds total voted nodes");

        unchecked {
            uint256 size = _to - _from + 1;
            string[] memory nodeList = new string[](size);
            uint256[] memory voteList = new uint256[](size);

            for (uint256 i; i < size; ++i) {
                string memory nodeId = userVotedNodes[msg.sender][_from + i];
                nodeList[i] = nodeId;
                voteList[i] = nodeUserVotedWeight[nodeId][msg.sender];
            }

            return (nodeList, voteList);
        }
    }
}
