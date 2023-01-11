pragma solidity ^0.8;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";

interface Comptroller {
    function getAllMarkets() external view returns (address[] memory);
    function mintGuardianPaused(address market) external view returns (bool);
    function borrowGuardianPaused(address market) external view returns (bool);
    function _setMintPaused(address qiToken, bool state) external returns (bool);
    function _setBorrowPaused(address qiToken, bool state) external returns (bool);
    function _setTransferPaused(bool state) external returns (bool);
    function _setSeizePaused(bool state) external returns (bool);
}

interface ProofOfReserveFeed {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

interface QiToken {
    function underlying() external view returns (address);
}

interface UnderlyingToken {
    function totalSupply() external view returns (uint);
}

contract PauseGuardian is Ownable, AutomationCompatible {
    Comptroller public constant comptroller = Comptroller(0x486Af39519B4Dc9a7fCcd318217352830E8AD9b4);

    address[] public markets;
    mapping(address => address) public proofOfReserveFeeds;

    constructor() {
        transferOwnership(0x30d62267874DdA4D32Bb28ddD713f77d1aa99159);

        // BTC.b
        _setProofOfReserveFeed(0x89a415b3D20098E6A6C8f7a59001C67BD3129821, 0x99311B4bf6D8E3D3B4b9fbdD09a1B0F4Ad8e06E9);

        // DAI.e
        _setProofOfReserveFeed(0x835866d37AFB8CB8F8334dCCdaf66cf01832Ff5D, 0x976D7fAc81A49FA71EF20694a3C56B9eFB93c30B);

        // LINK.e
        _setProofOfReserveFeed(0x4e9f683A27a6BdAD3FC2764003759277e93696e6, 0x943cEF1B112Ca9FD7EDaDC9A46477d3812a382b6);

        // WBTC.e
        _setProofOfReserveFeed(0xe194c4c5aC32a3C9ffDb358d9Bfd523a0B6d1568, 0xebEfEAA58636DF9B20a4fAd78Fad8759e6A20e87);

        // WETH.e
        _setProofOfReserveFeed(0x334AD834Cd4481BB02d09615E7c11a00579A7909, 0xDDaf9290D057BfA12d7576e6dADC109421F31948);
    }

    function pauseMintingAndBorrowingForAllMarkets() external onlyOwner {
        _pauseMintingAndBorrowingForAllMarkets();
    }

    function _pauseMintingAndBorrowingForAllMarkets() internal {
        address[] memory allMarkets = comptroller.getAllMarkets();
        uint marketCount = allMarkets.length;

        for (uint i; i < marketCount; ++i) {
            comptroller._setMintPaused(allMarkets[i], true);
            comptroller._setBorrowPaused(allMarkets[i], true);
        }
    }

    function pauseMintingAndBorrowingForMarket(address qiToken) external onlyOwner {
        comptroller._setMintPaused(qiToken, true);
        comptroller._setBorrowPaused(qiToken, true);
    }

    function pauseMinting(address qiToken) external onlyOwner {
        comptroller._setMintPaused(qiToken, true);
    }

    function pauseBorrowing(address qiToken) external onlyOwner {
        comptroller._setBorrowPaused(qiToken, true);
    }

    function pauseTransfers() external onlyOwner {
        comptroller._setTransferPaused(true);
    }

    function pauseLiquidations() external onlyOwner {
        comptroller._setSeizePaused(true);
    }

    function proofOfReservesPause() public {
        require(_canPause(), "Proof of reserves are OK");

        _pauseMintingAndBorrowingForAllMarkets();
    }

    function _canPause() internal view returns (bool) {
        uint marketCount = markets.length;

        for (uint i; i < marketCount; ++i) {
            address qiTokenAddress = markets[i];
            ProofOfReserveFeed proofOfReserveFeed = ProofOfReserveFeed(proofOfReserveFeeds[qiTokenAddress]);

            uint underlyingTokenTotalSupply = UnderlyingToken(QiToken(qiTokenAddress).underlying()).totalSupply();
            (, int256 proofOfReserveAnswer, , ,) = proofOfReserveFeed.latestRoundData();

            if (underlyingTokenTotalSupply > uint256(proofOfReserveAnswer)) {
                return true;
            }
        }

        return false;
    }

    function canPause() external view returns (bool) {
        return _canPause();
    }

    function _areAllMarketsPaused() internal view returns (bool) {
        address[] memory allMarkets = comptroller.getAllMarkets();
        uint marketCount = allMarkets.length;

        for (uint i; i < marketCount; ++i) {
            if (!comptroller.mintGuardianPaused(allMarkets[i]) || !comptroller.borrowGuardianPaused(allMarkets[i])) {
                return false;
            }
        }

        return true;
    }

    function areAllMarketsPaused() external view returns (bool) {
        return _areAllMarketsPaused();
    }

    function setProofOfReserveFeed(address qiToken, address feed) external onlyOwner {
        _setProofOfReserveFeed(qiToken, feed);
    }

    function _setProofOfReserveFeed(address qiToken, address feed) internal {
        if (proofOfReserveFeeds[qiToken] == address(0)) {
            markets.push(qiToken);
        }

        proofOfReserveFeeds[qiToken] = feed;
    }

    function removeProofOfReserveFeed(address qiToken) external onlyOwner {
        delete proofOfReserveFeeds[qiToken];

        uint marketCount = markets.length;
        for (uint i; i < marketCount; ++i) {
            if (markets[i] == qiToken) {
                if (i != marketCount - 1) {
                    markets[i] = markets[marketCount - 1];
                }

                markets.pop();
                break;
            }
        }
    }

    function checkUpkeep(bytes calldata) external view returns (
        bool upkeepNeeded,
        bytes memory performData
    ) {
        upkeepNeeded = _canPause() && !_areAllMarketsPaused();
        performData = new bytes(0);
    }

    function performUpkeep(bytes calldata) external {
        proofOfReservesPause();
    }
}
