// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ICurve} from "./bonding-curves/ICurve.sol";
import {LSSVMPair} from "./LSSVMPair.sol";
import {ILSSVMPairFactoryLike} from "./ILSSVMPairFactoryLike.sol";
import {CurveErrorCodes} from "./bonding-curves/CurveErrorCodes.sol";

/// @title An NFT/Token pair with a price (and liquidity?) oracle
/// @notice This inherits from the base contract to include an oracle
/// @dev Optimistically writes observations to oracle based on last swap
abstract contract LSSVMPairWithOracle is LSSVMPair {
    // TODO: using Oracle for Oracle.Observation[];
    // TODO: Orace.Observation[] public observations;

    /**
     * External state-changing functions
     */

    /**
        @notice Sends token to the pair in exchange for any `numNFTs` NFTs
        @dev To compute the amount of token to send, call bondingCurve.getBuyInfo.
        This swap function is meant for users who are ID agnostic
        @dev Overrides base swapTokenForAnyNFTs to optimistically write to oracle prior to calcs and swap.
        @param numNFTs The number of NFTs to purchase
        @param maxExpectedTokenInput The maximum acceptable cost from the sender. If the actual
        amount is greater than this value, the transaction will be reverted.
        @param nftRecipient The recipient of the NFTs
        @param isRouter True if calling from LSSVMRouter, false otherwise. Not used for
        ETH pairs.
        @param routerCaller If isRouter is true, ERC20 tokens will be transferred from this address. Not used for
        ETH pairs.
        @return inputAmount The amount of token used for purchase
     */
    function swapTokenForAnyNFTs(
        uint256 numNFTs,
        uint256 maxExpectedTokenInput,
        address nftRecipient,
        bool isRouter,
        address routerCaller
    )
        external
        payable
        virtual
        override
        nonReentrant
        returns (uint256 inputAmount)
    {
        // Store locally to remove extra calls
        ILSSVMPairFactoryLike _factory = factory();
        ICurve _bondingCurve = bondingCurve();
        IERC721 _nft = nft();

        // Input validation
        {
            PoolType _poolType = poolType();
            require(
                _poolType == PoolType.NFT || _poolType == PoolType.TRADE,
                "Wrong Pool type"
            );
            require(
                (numNFTs > 0) && (numNFTs <= _nft.balanceOf(address(this))),
                "Ask for > 0 and <= balanceOf NFTs"
            );
        }

        // Call bonding curve for pricing information
        // @dev uses calculate buy info + update to also write to oracle
        uint256 protocolFee;
        (
            protocolFee,
            inputAmount
        ) = _calculateBuyInfoAndUpdatePoolParamsWithOracle(
            numNFTs,
            maxExpectedTokenInput,
            _bondingCurve,
            _factory
        );

        _pullTokenInputAndPayProtocolFee(
            inputAmount,
            isRouter,
            routerCaller,
            _factory,
            protocolFee
        );

        _sendAnyNFTsToRecipient(_nft, nftRecipient, numNFTs);

        _refundTokenToSender(inputAmount);

        emit SwapNFTOutPair();
    }

    /**
        @notice Sends token to the pair in exchange for a specific set of NFTs
        @dev To compute the amount of token to send, call bondingCurve.getBuyInfo
        This swap is meant for users who want specific IDs. Also higher chance of
        reverting if some of the specified IDs leave the pool before the swap goes through.
        @dev Overrides base swapTokenForSpecificNFTs to optimistically write to oracle prior to calcs and swap.
        @param nftIds The list of IDs of the NFTs to purchase
        @param maxExpectedTokenInput The maximum acceptable cost from the sender. If the actual
        amount is greater than this value, the transaction will be reverted.
        @param nftRecipient The recipient of the NFTs
        @param isRouter True if calling from LSSVMRouter, false otherwise. Not used for
        ETH pairs.
        @param routerCaller If isRouter is true, ERC20 tokens will be transferred from this address. Not used for
        ETH pairs.
        @return inputAmount The amount of token used for purchase
     */
    function swapTokenForSpecificNFTs(
        uint256[] calldata nftIds,
        uint256 maxExpectedTokenInput,
        address nftRecipient,
        bool isRouter,
        address routerCaller
    )
        external
        payable
        virtual
        override
        nonReentrant
        returns (uint256 inputAmount)
    {
        // Store locally to remove extra calls
        ILSSVMPairFactoryLike _factory = factory();
        ICurve _bondingCurve = bondingCurve();

        // Input validation
        {
            PoolType _poolType = poolType();
            require(
                _poolType == PoolType.NFT || _poolType == PoolType.TRADE,
                "Wrong Pool type"
            );
            require((nftIds.length > 0), "Must ask for > 0 NFTs");
        }

        // Call bonding curve for pricing information
        uint256 protocolFee;
        (
            protocolFee,
            inputAmount
        ) = _calculateBuyInfoAndUpdatePoolParamsWithOracle(
            nftIds.length,
            maxExpectedTokenInput,
            _bondingCurve,
            _factory
        );

        _pullTokenInputAndPayProtocolFee(
            inputAmount,
            isRouter,
            routerCaller,
            _factory,
            protocolFee
        );

        _sendSpecificNFTsToRecipient(nft(), nftRecipient, nftIds);

        _refundTokenToSender(inputAmount);

        emit SwapNFTOutPair();
    }

    /**
        @notice Sends a set of NFTs to the pair in exchange for token
        @dev To compute the amount of token to that will be received, call bondingCurve.getSellInfo.
        @dev Overrides base swapNFTForToken to optimistically write to oracle prior to calcs and swap.
        @param nftIds The list of IDs of the NFTs to sell to the pair
        @param minExpectedTokenOutput The minimum acceptable token received by the sender. If the actual
        amount is less than this value, the transaction will be reverted.
        @param tokenRecipient The recipient of the token output
        @param isRouter True if calling from LSSVMRouter, false otherwise. Not used for
        ETH pairs.
        @param routerCaller If isRouter is true, ERC20 tokens will be transferred from this address. Not used for
        ETH pairs.
        @return outputAmount The amount of token received
     */
    function swapNFTsForToken(
        uint256[] calldata nftIds,
        uint256 minExpectedTokenOutput,
        address payable tokenRecipient,
        bool isRouter,
        address routerCaller
    ) external virtual override nonReentrant returns (uint256 outputAmount) {
        // Store locally to remove extra calls
        ILSSVMPairFactoryLike _factory = factory();
        ICurve _bondingCurve = bondingCurve();

        // Input validation
        {
            PoolType _poolType = poolType();
            require(
                _poolType == PoolType.TOKEN || _poolType == PoolType.TRADE,
                "Wrong Pool type"
            );
            require(nftIds.length > 0, "Must ask for > 0 NFTs");
        }

        // Call bonding curve for pricing information
        uint256 protocolFee;
        (
            protocolFee,
            outputAmount
        ) = _calculateSellInfoAndUpdatePoolParamsWithOracle(
            nftIds.length,
            minExpectedTokenOutput,
            _bondingCurve,
            _factory
        );

        _sendTokenOutput(tokenRecipient, outputAmount);

        _payProtocolFeeFromPair(_factory, protocolFee);

        _takeNFTsFromSender(nft(), nftIds, _factory, isRouter, routerCaller);

        emit SwapNFTInPair();
    }

    /**
        @notice Calculates the amount needed to be sent into the pair for a buy and adjusts spot price or delta if necessary
        @dev Optimistically writes to oracle if price has changed
        @param numNFTs The amount of NFTs to purchase from the pair
        @param maxExpectedTokenInput The maximum acceptable cost from the sender. If the actual
        amount is greater than this value, the transaction will be reverted.
        @param protocolFee The percentage of protocol fee to be taken, as a percentage
        @return protocolFee The amount of tokens to send as protocol fee
        @return inputAmount The amount of tokens total tokens receive
     */
    function _calculateBuyInfoAndUpdatePoolParamsWithOracle(
        uint256 numNFTs,
        uint256 maxExpectedTokenInput,
        ICurve _bondingCurve,
        ILSSVMPairFactoryLike _factory
    ) internal returns (uint256 protocolFee, uint256 inputAmount) {
        CurveErrorCodes.Error error;
        // Save on 2 SLOADs by caching
        uint128 currentSpotPrice = spotPrice;
        uint128 newSpotPrice;
        uint128 currentDelta = delta;
        uint128 newDelta;
        (
            error,
            newSpotPrice,
            newDelta,
            inputAmount,
            protocolFee
        ) = _bondingCurve.getBuyInfo(
            currentSpotPrice,
            currentDelta,
            numNFTs,
            fee,
            _factory.protocolFeeMultiplier()
        );

        // Revert if bonding curve had an error
        if (error != CurveErrorCodes.Error.OK) {
            revert BondingCurveError(error);
        }

        // Revert if input is more than expected
        require(inputAmount <= maxExpectedTokenInput, "In too many tokens");

        // Consolidate writes to save gas
        if (currentSpotPrice != newSpotPrice || currentDelta != newDelta) {
            spotPrice = newSpotPrice;
            delta = newDelta;
        }

        // Emit spot price update if it has been updated and write last price
        // observation to oracle
        if (currentSpotPrice != newSpotPrice) {
            // use spotPrice prior to swap to write to observations
            _writeObservationToOracle(currentSpotPrice);

            // emit update event
            emit SpotPriceUpdate(newSpotPrice);
        }

        // Emit delta update if it has been updated
        if (currentDelta != newDelta) {
            emit DeltaUpdate(newDelta);
        }
    }

    /**
        @notice Calculates the amount needed to be sent by the pair for a sell and adjusts spot price or delta if necessary
        @dev Optimistically writes to oracle if price has changed
        @param numNFTs The amount of NFTs to send to the the pair
        @param minExpectedTokenOutput The minimum acceptable token received by the sender. If the actual
        amount is less than this value, the transaction will be reverted.
        @param protocolFee The percentage of protocol fee to be taken, as a percentage
        @return protocolFee The amount of tokens to send as protocol fee
        @return outputAmount The amount of tokens total tokens receive
     */
    function _calculateSellInfoAndUpdatePoolParamsWithOracle(
        uint256 numNFTs,
        uint256 minExpectedTokenOutput,
        ICurve _bondingCurve,
        ILSSVMPairFactoryLike _factory
    ) internal returns (uint256 protocolFee, uint256 outputAmount) {
        CurveErrorCodes.Error error;
        // Save on 2 SLOADs by caching
        uint128 currentSpotPrice = spotPrice;
        uint128 newSpotPrice;
        uint128 currentDelta = delta;
        uint128 newDelta;
        (
            error,
            newSpotPrice,
            newDelta,
            outputAmount,
            protocolFee
        ) = _bondingCurve.getSellInfo(
            currentSpotPrice,
            currentDelta,
            numNFTs,
            fee,
            _factory.protocolFeeMultiplier()
        );

        // Revert if bonding curve had an error
        if (error != CurveErrorCodes.Error.OK) {
            revert BondingCurveError(error);
        }

        // Revert if output is too little
        require(
            outputAmount >= minExpectedTokenOutput,
            "Out too little tokens"
        );

        // Consolidate writes to save gas
        if (currentSpotPrice != newSpotPrice || currentDelta != newDelta) {
            spotPrice = newSpotPrice;
            delta = newDelta;
        }

        // Emit spot price update if it has been updated and write last price
        // observation to oracle
        if (currentSpotPrice != newSpotPrice) {
            // use spotPrice prior to swap to write to observations
            _writeObservationToOracle(currentSpotPrice);

            // emit update event
            emit SpotPriceUpdate(newSpotPrice);
        }

        // Emit delta update if it has been updated
        if (currentDelta != newDelta) {
            emit DeltaUpdate(newDelta);
        }
    }

    /// @notice Writes an observation of the last price to the oracle prior to swap execution.
    function _writeObservationToOracle(uint128 spotPrice) internal {}
}
