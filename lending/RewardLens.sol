pragma solidity 0.5.17;

import "./ExponentialNoError.sol";
import "./Comptroller.sol";
import "./QiToken.sol";

contract RewardLens is ExponentialNoError {
    Comptroller public constant comptroller = Comptroller(0x486Af39519B4Dc9a7fCcd318217352830E8AD9b4);

    function getClaimableRewards(address user) public view returns (uint, uint, address[] memory) {
        (uint claimableQi, address[] memory qiMarkets) = getClaimableReward(user, 0);
        (uint claimableAvax, address[] memory avaxMarkets) = getClaimableReward(user, 1);

        uint numQiMarkets = qiMarkets.length;
        uint numAvaxMarkets = avaxMarkets.length;
        address[] memory rewardMarkets = new address[](numQiMarkets + numAvaxMarkets);

        for (uint i; i < numQiMarkets; ++i) {
            rewardMarkets[i] = qiMarkets[i];
        }

        for (uint i; i < numAvaxMarkets; ++i) {
            rewardMarkets[i + numQiMarkets] = avaxMarkets[i];
        }

        return (claimableQi, claimableAvax, rewardMarkets);
    }

    function getClaimableReward(address user, uint8 rewardType) public view returns (uint, address[] memory) {
        QiToken[] memory markets = comptroller.getAllMarkets();
        uint numMarkets = markets.length;

        uint accrued = comptroller.rewardAccrued(rewardType, user);

        Exp memory borrowIndex;
        uint224 rewardIndex;

        uint totalMarketAccrued;

        address[] memory marketsWithRewards = new address[](numMarkets);
        uint numMarketsWithRewards;

        for (uint i; i < numMarkets; ++i) {
            borrowIndex = Exp({mantissa: markets[i].borrowIndex()});

            rewardIndex = updateRewardSupplyIndex(rewardType, address(markets[i]));
            totalMarketAccrued = distributeSupplierReward(rewardType, address(markets[i]), user, rewardIndex);

            rewardIndex = updateRewardBorrowIndex(rewardType, address(markets[i]), borrowIndex);
            totalMarketAccrued += distributeBorrowerReward(rewardType, address(markets[i]), user, borrowIndex, rewardIndex);

            accrued += totalMarketAccrued;

            if (totalMarketAccrued > 0) {
                marketsWithRewards[numMarketsWithRewards++] = address(markets[i]);
            }
        }

        return (accrued, marketsWithRewards);
    }

    function updateRewardBorrowIndex(
        uint8 rewardType,
        address qiToken,
        Exp memory marketBorrowIndex
    ) internal view returns (uint224) {
        (uint224 borrowStateIndex, uint32 borrowStateTimestamp) = comptroller.rewardBorrowState(rewardType, qiToken);
        uint borrowSpeed = comptroller.borrowRewardSpeeds(rewardType, qiToken);
        uint32 blockTimestamp = uint32(block.timestamp);
        uint deltaTimestamps = sub_(blockTimestamp, uint(borrowStateTimestamp));

        if (deltaTimestamps > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(QiToken(qiToken).totalBorrows(), marketBorrowIndex);
            uint rewardAccrued = mul_(deltaTimestamps, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(rewardAccrued, borrowAmount) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: borrowStateIndex}), ratio);

            return uint224(index.mantissa);
        }

        return borrowStateIndex;
    }

    function updateRewardSupplyIndex(
        uint8 rewardType,
        address qiToken
    ) internal view returns (uint224) {
        (uint224 supplyStateIndex, uint32 supplyStateTimestamp) = comptroller.rewardSupplyState(rewardType, qiToken);
        uint supplySpeed = comptroller.supplyRewardSpeeds(rewardType, qiToken);
        uint32 blockTimestamp = uint32(block.timestamp);
        uint deltaTimestamps = sub_(blockTimestamp, uint(supplyStateTimestamp));

        if (deltaTimestamps > 0 && supplySpeed > 0) {
            uint supplyTokens = QiToken(qiToken).totalSupply();
            uint rewardAccrued = mul_(deltaTimestamps, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(rewardAccrued, supplyTokens) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: supplyStateIndex}), ratio);

            return uint224(index.mantissa);
        }

        return supplyStateIndex;
    }

    function distributeBorrowerReward(
        uint8 rewardType,
        address qiToken,
        address borrower,
        Exp memory marketBorrowIndex,
        uint224 borrowStateIndex
    ) internal view returns (uint256) {
        Double memory borrowIndex = Double({mantissa: borrowStateIndex});
        Double memory borrowerIndex = Double({mantissa: comptroller.rewardBorrowerIndex(rewardType, qiToken, borrower)});

        if (borrowerIndex.mantissa > 0) {
            Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
            uint borrowerAmount = div_(QiToken(qiToken).borrowBalanceStored(borrower), marketBorrowIndex);
            uint borrowerDelta = mul_(borrowerAmount, deltaIndex);

            return borrowerDelta;
        }

        return 0;
    }

    function distributeSupplierReward(
        uint8 rewardType,
        address qiToken,
        address supplier,
        uint224 supplyStateIndex
    ) internal view returns (uint256) {
        Double memory supplyIndex = Double({mantissa: supplyStateIndex});
        Double memory supplierIndex = Double({mantissa: comptroller.rewardSupplierIndex(rewardType, qiToken, supplier)});

        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = comptroller.initialIndexConstant();
        }

        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        uint supplierTokens = QiToken(qiToken).balanceOf(supplier);
        uint supplierDelta = mul_(supplierTokens, deltaIndex);

        return supplierDelta;
    }
}
