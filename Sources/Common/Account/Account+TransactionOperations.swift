//
//  Copyright (c) 2020-2021 MobileCoin. All rights reserved.
//

// swiftlint:disable closure_body_length function_body_length multiline_arguments type_body_length

import Foundation

extension Account {
    struct TransactionOperations {
        private let serialQueue: DispatchQueue
        private let account: ReadWriteDispatchLock<Account>
        private let metaFetcher: BlockchainMetaFetcher
        private let txOutSelector: TxOutSelector
        private let transactionPreparer: TransactionPreparer

        init(
            account: ReadWriteDispatchLock<Account>,
            fogMerkleProofService: FogMerkleProofService,
            fogResolverManager: FogResolverManager,
            metaFetcher: BlockchainMetaFetcher,
            txOutSelectionStrategy: TxOutSelectionStrategy,
            mixinSelectionStrategy: MixinSelectionStrategy,
            rngSeed: RngSeed,
            targetQueue: DispatchQueue?
        ) {
            self.serialQueue = DispatchQueue(
                label: "com.mobilecoin.\(Account.self).\(Self.self))",
                target: targetQueue)
            self.account = account
            self.metaFetcher = metaFetcher
            self.txOutSelector = TxOutSelector(txOutSelectionStrategy: txOutSelectionStrategy)
            self.transactionPreparer = TransactionPreparer(
                accountKey: account.accessWithoutLocking.accountKey,
                fogMerkleProofService: fogMerkleProofService,
                fogResolverManager: fogResolverManager,
                mixinSelectionStrategy: mixinSelectionStrategy,
                rngSeed: rngSeed,
                targetQueue: targetQueue)
        }

        func prepareTransaction(
            to recipient: PublicAddress,
            memoType: MemoType,
            amount: Amount,
            fee: UInt64,
            completion: @escaping (
                Result<PendingSinglePayloadTransaction, TransactionPreparationError>
            ) -> Void
        ) {
            guard amount.value > 0 else {
                let errorMessage = "prepareTransactionWithFee failure: " +
                    "Cannot spend 0 \(amount.tokenId)"
                logger.error(errorMessage, logFunction: false)
                serialQueue.async {
                    completion(.failure(.invalidInput(errorMessage)))
                }
                return
            }

            let (unspentTxOuts, ledgerBlockCount) = account.readSync {
                    ($0.unspentTxOuts(tokenId: amount.tokenId), $0.knowableBlockCount)
            }
            logger.info(
                "Preparing transaction with provided fee... recipient: \(redacting: recipient), " +
                    "amount: \(redacting: amount), fee: \(redacting: fee), unspentTxOutValues: " +
                    "\(redacting: unspentTxOuts.map { $0.value })",
                logFunction: false)
            switch txOutSelector
                .selectTransactionInputs(amount: amount, fee: fee, fromTxOuts: unspentTxOuts)
                .mapError({ error -> TransactionPreparationError in
                    switch error {
                    case .insufficientTxOuts:
                        return .insufficientBalance()
                    case .defragmentationRequired:
                        return .defragmentationRequired()
                    }
                })
            {
            case .success(let txOutsToSpend):
                metaFetcher.blockVersion {
                    switch $0 {
                    case .success(let blockVersion):
                        logger.info(
                            "Transaction prepared with fee. txOutsToSpend: " +
                                """
                                    0x\(redacting: txOutsToSpend.map {
                                        $0.publicKey.hexEncodedString()
                                    })
                                """,
                            logFunction: false)
                        let tombstoneBlockIndex = ledgerBlockCount + 50
                        transactionPreparer.prepareTransaction(
                            inputs: txOutsToSpend,
                            recipient: recipient,
                            memoType: memoType,
                            amount: amount,
                            fee: Amount(fee, in: amount.tokenId),
                            tombstoneBlockIndex: tombstoneBlockIndex,
                            blockVersion: blockVersion,
                            completion: completion)
                    case .failure(let error):
                        logger.info(
                            "prepareTransactionWithFee failure: \(error)",
                            logFunction: false)

                        serialQueue.async {
                            completion(.failure(.connectionError(error)))
                        }
                    }
                }

            case .failure(let error):
                logger.info("prepareTransactionWithFee failure: \(error)", logFunction: false)
                serialQueue.async {
                    completion(.failure(error))
                }
            }
        }

        func prepareTransaction(
            to recipient: PublicAddress,
            memoType: MemoType,
            amount: Amount,
            feeLevel: FeeLevel,
            completion: @escaping (
                Result<PendingSinglePayloadTransaction, TransactionPreparationError>
            ) -> Void
        ) {
            guard amount.value > 0 else {
                let errorMessage = "prepareTransactionWithFeeLevel failure: " +
                    "Cannot spend 0 \(amount.tokenId)"
                logger.error(errorMessage, logFunction: false)
                serialQueue.async {
                    completion(.failure(.invalidInput(errorMessage)))
                }
                return
            }

            metaFetcher.feeStrategy(for: feeLevel, tokenId: amount.tokenId) {
                switch $0 {
                case .success(let feeStrategy):
                    let (unspentTxOuts, ledgerBlockCount) =
                        self.account.readSync {
                            ($0.unspentTxOuts(tokenId: amount.tokenId), $0.knowableBlockCount)
                        }
                    logger.info(
                        "Preparing transaction with fee level... recipient: " +
                            "\(redacting: recipient), amount: \(redacting: amount), feeLevel: " +
                            "\(feeLevel), unspentTxOutValues: " +
                            "\(redacting: unspentTxOuts.map { $0.value })",
                        logFunction: false)
                    switch self.txOutSelector
                        .selectTransactionInputs(
                            amount: amount,
                            feeStrategy: feeStrategy,
                            fromTxOuts: unspentTxOuts)
                        .mapError({ error -> TransactionPreparationError in
                            switch error {
                            case .insufficientTxOuts:
                                return .insufficientBalance()
                            case .defragmentationRequired:
                                return .defragmentationRequired()
                            }
                        })
                    {
                    case .success(let (inputs: inputs, fee: fee)):
                        metaFetcher.blockVersion {
                            switch $0 {
                            case .success(let blockVersion):
                                logger.info(
                                    "Transaction prepared with fee level. fee: \(redacting: fee)",
                                    logFunction: false)
                                let tombstoneBlockIndex = ledgerBlockCount + 50
                                self.transactionPreparer.prepareTransaction(
                                    inputs: inputs,
                                    recipient: recipient,
                                    memoType: memoType,
                                    amount: amount,
                                    fee: Amount(fee, in: amount.tokenId),
                                    tombstoneBlockIndex: tombstoneBlockIndex,
                                    blockVersion: blockVersion,
                                    completion: completion)
                            case .failure(let error):
                                logger.info(
                                    "prepareTransactionWithFee failure: \(error)",
                                    logFunction: false)

                                serialQueue.async {
                                    completion(.failure(.connectionError(error)))
                                }
                            }
                        }
                    case .failure(let error):
                        logger.info(
                            "prepareTransactionWithFeeLevel failure: \(error)",
                            logFunction: false)
                        completion(.failure(error))
                    }
                case .failure(let connectionError):
                    logger.info("failure - error: \(connectionError)")
                    completion(.failure(.connectionError(connectionError)))
                }
            }
        }

        func prepareDefragmentationStepTransactions(
            toSendAmount amountToSend: Amount,
            recoverableMemo: Bool,
            feeLevel: FeeLevel,
            completion: @escaping (Result<[Transaction], DefragTransactionPreparationError>) -> Void
        ) {
            guard amountToSend.value > 0 else {
                let errorMessage =
                    "prepareDefragmentationStepTransactions failure: " +
                    "Cannot spend 0 \(amountToSend.tokenId)"
                logger.error(errorMessage, logFunction: false)
                serialQueue.async {
                    completion(.failure(.invalidInput(errorMessage)))
                }
                return
            }

            metaFetcher.feeStrategy(for: feeLevel, tokenId: amountToSend.tokenId) {
                switch $0 {
                case .success(let feeStrategy):
                    let (unspentTxOuts, ledgerBlockCount) =
                        self.account.readSync {
                            ($0.unspentTxOuts(tokenId: amountToSend.tokenId), $0.knowableBlockCount)
                        }
                    logger.info(
                        "Preparing defragmentation step transactions... amountToSend: " +
                            "\(redacting: amountToSend), feeLevel: \(feeLevel), " +
                            "unspentTxOutValues: \(redacting: unspentTxOuts.map { $0.value })",
                        logFunction: false)
                    switch self.txOutSelector.selectInputsForDefragTransactions(
                        toSendAmount: amountToSend,
                        feeStrategy: feeStrategy,
                        fromTxOuts: unspentTxOuts)
                    {
                    case .success(let defragTxInputs):
                        metaFetcher.blockVersion {
                            switch $0 {
                            case .success(let blockVersion):
                                if !defragTxInputs.isEmpty {
                                    logger.info(
                                        "Preparing \(defragTxInputs.count) defrag transactions",
                                        logFunction: false)
                                }
                                let tombstoneBlockIndex = ledgerBlockCount + 50
                                defragTxInputs.mapAsync({ defragInputs, callback in
                                    self.transactionPreparer.prepareSelfAddressedTransaction(
                                        inputs: defragInputs.inputs,
                                        recoverableMemo: recoverableMemo,
                                        fee: Amount(defragInputs.fee, in: amountToSend.tokenId),
                                        tombstoneBlockIndex: tombstoneBlockIndex,
                                        blockVersion: blockVersion,
                                        completion: callback)
                                }, serialQueue: self.serialQueue, completion: completion)
                            case .failure(let error):
                                logger.info(
                                    "prepareTransactionWithFee failure: \(error)",
                                    logFunction: false)

                                serialQueue.async {
                                    completion(.failure(.connectionError(error)))
                                }
                            }
                        }
                    case .failure(let error):
                        logger.info(
                            "prepareDefragmentationStepTransactions failure: \(error)",
                            logFunction: false)
                        self.serialQueue.async {
                            completion(.failure(.insufficientBalance()))
                        }
                    }
                case .failure(let connectionError):
                    logger.info("failure - error: \(connectionError)")
                    completion(.failure(.connectionError(connectionError)))
                }
            }
        }

        /// Prepare a partial-fill swap (MCIP-42 taker side).
        ///
        /// The taker pays `payCounterAmount` of the SCI's COUNTER token and receives
        /// `fillBaseAmount` of the SCI's BASE token. `sciChangeBaseAmount` is the SCI's
        /// unfilled remainder (= `sci.partialFillMaxBase - fillBaseAmount`); the caller
        /// (KyotoSwapBuilder) is responsible for computing it from the wire-level SCI
        /// metadata DEQS already exposes (so the SDK never has to unmask `RevealedTxOut`).
        ///
        /// The fee is always in MOB. Two directions:
        ///   * counter == MOB (mob→eusd): selection covers `payCounterAmount + fee`;
        ///     fee is deducted from the taker's COUNTER change in TransactionBuilder.
        ///   * counter != MOB (eusd→mob): selection covers `payCounterAmount` only;
        ///     fee is deducted from the taker's BASE receive in TransactionBuilder.
        func preparePartialFillSwapTransaction(
            presignedInput: SignedContingentInput,
            fillBaseAmount: Amount,
            sciChangeBaseAmount: Amount,
            payCounterAmount: Amount,
            fee: Amount,
            completion: @escaping (Result<PendingTransaction, TransactionPreparationError>)
            -> Void
        ) {
            // For an MCIP-42 partial-fill SCI:
            //   pseudo_output_amount.token_id     = BASE   (maker's input UTXO)
            //   required_output_amounts[0]        = BASE   (maker's untradeable self-payment)
            //   input_rules.partial_fill_outputs  = COUNTER (what maker wants from taker)
            // The Swift `SignedContingentInput` wrapper exposes pseudoOutput / requiredAmount
            // but not partialFillOutputs, so the COUNTER token is established by the caller
            // via `payCounterAmount` (which DEQS supplies via the Pair on each Quote).
            let counterTokenId = payCounterAmount.tokenId

            guard fillBaseAmount.tokenId == sciChangeBaseAmount.tokenId,
                  fillBaseAmount.tokenId != counterTokenId
            else {
                serialQueue.async {
                    completion(.failure(.invalidInput(
                        "fill/sciChange tokenId must match each other and differ from counter.")))
                }
                return
            }
            guard payCounterAmount.value > 0, fillBaseAmount.value > 0 else {
                serialQueue.async {
                    completion(.failure(.invalidInput(
                        "payCounterAmount and fillBaseAmount must be > 0.")))
                }
                return
            }

            let (unspentTxOuts, ledgerBlockCount) = account.readSync {
                ($0.unspentTxOuts(tokenId: counterTokenId), $0.knowableBlockCount)
            }

            guard ledgerBlockCount <= presignedInput.tombstoneBlockIndex else {
                serialQueue.async {
                    completion(.failure(.invalidInput("Presigned Input Expired.")))
                }
                return
            }

            // Fee is always MOB. If counter == MOB, we need to fund the fee from counter
            // inputs; if counter != MOB, the fee comes out of the BASE receive (handled in
            // TransactionBuilder.buildPartialFillSwap).
            let feeFromCounter: UInt64 = (counterTokenId == fee.tokenId) ? fee.value : 0

            logger.info(
                "Preparing partial-fill swap... counterTokenId: \(counterTokenId), " +
                    "payCounter: \(redacting: payCounterAmount), " +
                    "fillBase: \(redacting: fillBaseAmount), " +
                    "sciChangeBase: \(redacting: sciChangeBaseAmount), " +
                    "fee: \(redacting: fee), feeFromCounter: \(feeFromCounter), " +
                    "unspentTxOutValues: \(redacting: unspentTxOuts.map { $0.value })",
                logFunction: false)

            // Reserve one of the MAX_INPUTS ring-signed input slots for the SCI itself.
            // Without this cap, the strategy's opportunistic dust-cleanup will fill all
            // 16 slots with taker UTXOs and the resulting tx (16 user inputs + 1 SCI =
            // 17 inputs) is rejected by consensus with `tooManyInputs`.
            switch txOutSelector
                .selectTransactionInputs(
                    amount: payCounterAmount,
                    fee: feeFromCounter,
                    fromTxOuts: unspentTxOuts,
                    maxInputs: McConstants.MAX_INPUTS - 1)
                .mapError({ error -> TransactionPreparationError in
                    switch error {
                    case .insufficientTxOuts:
                        return .insufficientBalance()
                    case .defragmentationRequired:
                        return .defragmentationRequired()
                    }
                })
            {
            case .success(let inputs):
                metaFetcher.blockVersion {
                    switch $0 {
                    case .success(let blockVersion):
                        let tombstoneBlockIndex =
                            min(ledgerBlockCount + 50, presignedInput.tombstoneBlockIndex)
                        self.transactionPreparer.preparePartialFillSwapTransaction(
                            presignedInput: presignedInput,
                            inputs: inputs,
                            fillBaseAmount: fillBaseAmount,
                            sciChangeBaseAmount: sciChangeBaseAmount,
                            fee: fee,
                            tombstoneBlockIndex: tombstoneBlockIndex,
                            blockVersion: blockVersion,
                            completion: completion)
                    case .failure(let error):
                        logger.info(
                            "preparePartialFillSwapTransaction failure: \(error)",
                            logFunction: false)
                        serialQueue.async {
                            completion(.failure(.connectionError(error)))
                        }
                    }
                }
            case .failure(let error):
                logger.info(
                    "preparePartialFillSwapTransaction failure: \(error)",
                    logFunction: false)
                serialQueue.async {
                    completion(.failure(error))
                }
            }
        }

        /// Multi-SCI array variant of `preparePartialFillSwapTransaction`.
        ///
        /// All SCIs MUST share `(baseTokenId, counterTokenId)`. The taker's `payCounterAmount`
        /// is the sum of per-SCI counter payments; aggregating selection here keeps the
        /// inner builder oblivious to multi-SCI accounting.
        ///
        /// Tombstone is `min(ledgerBlockCount + 50, min(SCI tombstones))` — the earliest
        /// expiry across the bundle bounds tx validity.
        func preparePartialFillSwapTransaction(
            presignedInputs: [SignedContingentInput],
            fillBaseAmounts: [Amount],
            sciChangeBaseAmounts: [Amount],
            payCounterAmount: Amount,
            fee: Amount,
            completion: @escaping (Result<PendingTransaction, TransactionPreparationError>)
            -> Void
        ) {
            guard !presignedInputs.isEmpty else {
                serialQueue.async {
                    completion(.failure(.invalidInput("Multi-SCI swap requires at least one SCI.")))
                }
                return
            }
            guard presignedInputs.count == fillBaseAmounts.count,
                  presignedInputs.count == sciChangeBaseAmounts.count else {
                serialQueue.async {
                    completion(.failure(.invalidInput(
                        "presignedInputs / fillBaseAmounts / sciChangeBaseAmounts count mismatch.")))
                }
                return
            }
            let counterTokenId = payCounterAmount.tokenId
            let baseTokenId = fillBaseAmounts[0].tokenId

            for i in 0..<fillBaseAmounts.count {
                guard fillBaseAmounts[i].tokenId == baseTokenId,
                      sciChangeBaseAmounts[i].tokenId == baseTokenId else {
                    serialQueue.async {
                        completion(.failure(.invalidInput(
                            "All fillBaseAmounts/sciChangeBaseAmounts must share base token id.")))
                    }
                    return
                }
            }
            guard baseTokenId != counterTokenId else {
                serialQueue.async {
                    completion(.failure(.invalidInput(
                        "BASE token id must differ from COUNTER token id.")))
                }
                return
            }
            guard payCounterAmount.value > 0,
                  fillBaseAmounts.allSatisfy({ $0.value > 0 }) else {
                serialQueue.async {
                    completion(.failure(.invalidInput(
                        "payCounterAmount and all fillBaseAmounts must be > 0.")))
                }
                return
            }

            let (unspentTxOuts, ledgerBlockCount) = account.readSync {
                ($0.unspentTxOuts(tokenId: counterTokenId), $0.knowableBlockCount)
            }

            let minSciTombstone = presignedInputs
                .map { $0.tombstoneBlockIndex }
                .min() ?? 0
            guard ledgerBlockCount <= minSciTombstone else {
                serialQueue.async {
                    completion(.failure(.invalidInput("Presigned Input Expired.")))
                }
                return
            }

            let feeFromCounter: UInt64 = (counterTokenId == fee.tokenId) ? fee.value : 0

            logger.info(
                "Preparing multi-SCI partial-fill swap... " +
                    "sciCount: \(presignedInputs.count), counterTokenId: \(counterTokenId), " +
                    "payCounter: \(redacting: payCounterAmount), " +
                    "fillBaseSum: \(redacting: fillBaseAmounts.map { $0.value }), " +
                    "sciChangeBaseSum: \(redacting: sciChangeBaseAmounts.map { $0.value }), " +
                    "fee: \(redacting: fee), feeFromCounter: \(feeFromCounter), " +
                    "unspentTxOutValues: \(redacting: unspentTxOuts.map { $0.value })",
                logFunction: false)

            // Reserve a slot for each SCI input (MAX_INPUTS - N), so consensus
            // doesn't reject for tooManyInputs after we add the N partial-fill SCIs.
            let maxTakerInputs = McConstants.MAX_INPUTS - presignedInputs.count
            guard maxTakerInputs > 0 else {
                serialQueue.async {
                    completion(.failure(.invalidInput(
                        "Too many SCIs for MAX_INPUTS budget.")))
                }
                return
            }

            switch txOutSelector
                .selectTransactionInputs(
                    amount: payCounterAmount,
                    fee: feeFromCounter,
                    fromTxOuts: unspentTxOuts,
                    maxInputs: maxTakerInputs)
                .mapError({ error -> TransactionPreparationError in
                    switch error {
                    case .insufficientTxOuts:
                        return .insufficientBalance()
                    case .defragmentationRequired:
                        return .defragmentationRequired()
                    }
                })
            {
            case .success(let inputs):
                metaFetcher.blockVersion {
                    switch $0 {
                    case .success(let blockVersion):
                        let tombstoneBlockIndex =
                            min(ledgerBlockCount + 50, minSciTombstone)
                        self.transactionPreparer.preparePartialFillSwapTransaction(
                            presignedInputs: presignedInputs,
                            inputs: inputs,
                            fillBaseAmounts: fillBaseAmounts,
                            sciChangeBaseAmounts: sciChangeBaseAmounts,
                            fee: fee,
                            tombstoneBlockIndex: tombstoneBlockIndex,
                            blockVersion: blockVersion,
                            completion: completion)
                    case .failure(let error):
                        logger.info(
                            "preparePartialFillSwapTransaction (multi) failure: \(error)",
                            logFunction: false)
                        serialQueue.async {
                            completion(.failure(.connectionError(error)))
                        }
                    }
                }
            case .failure(let error):
                logger.info(
                    "preparePartialFillSwapTransaction (multi) failure: \(error)",
                    logFunction: false)
                serialQueue.async {
                    completion(.failure(error))
                }
            }
        }

        func preparePresignedInputTransaction(
            presignedInput: SignedContingentInput,
            memoType: MemoType,
            fee: Amount,
            completion: @escaping (Result<PendingTransaction, TransactionPreparationError>)
            -> Void
        ) {
            let amountToSend = presignedInput.requiredAmount
            let amountToReceive = presignedInput.rewardAmount

            let (unspentTxOuts, ledgerBlockCount) =
                self.account.readSync {
                    ($0.unspentTxOuts(tokenId: amountToSend.tokenId),
                     $0.knowableBlockCount)
                }

            guard ledgerBlockCount <= presignedInput.tombstoneBlockIndex else {
                serialQueue.async {
                    completion(.failure(.invalidInput("Presigned Input Expired.")))
                }
                return
            }

            guard amountToReceive.tokenId == fee.tokenId else {
                serialQueue.async {
                    completion(.failure(.invalidInput(
                        "Fee token ID must match presigned input's amount to receive token ID.")))
                }
                return
            }

            guard amountToReceive.value >= fee.value else {
                serialQueue.async {
                    completion(.failure(.invalidInput("Reward Amount < Fee.")))
                }
                return
            }

            logger.info(
                "Preparing pre-signed input transaction with fee: " +
                    "\(fee), unspentTxOutValues: " +
                    "\(redacting: unspentTxOuts.map { $0.value })",
                logFunction: false)

            switch self.txOutSelector
                .selectTransactionInput(
                    amount: amountToSend,
                    feeStrategy: FixedFeeStrategy(fee: 0), // zero fee for SCI calculation
                    fromTxOuts: unspentTxOuts)
                .mapError({ error -> TransactionPreparationError in
                    switch error {
                    case .insufficientTxOuts:
                        return .insufficientBalance()
                    case .defragmentationRequired:
                        return .defragmentationRequired()
                    }
                })
            {
            case .success(let (inputs: inputs, fee: _ )):
                metaFetcher.blockVersion {
                    switch $0 {
                    case .success(let blockVersion):
                        logger.info(
                            "Transaction with presigned input prepared with fee:" +
                                "fee: \(redacting: fee)",
                            logFunction: false)

                        let tombstoneBlockIndex =
                            min(ledgerBlockCount + 50, presignedInput.tombstoneBlockIndex)

                        self.transactionPreparer.preparePresignedInputTransaction(
                            presignedInput: presignedInput,
                            inputs: inputs,
                            memoType: memoType,
                            amount: amountToSend,
                            fee: fee,
                            tombstoneBlockIndex: tombstoneBlockIndex,
                            blockVersion: blockVersion,
                            completion: completion)
                    case .failure(let error):
                        logger.info(
                            "preparePresignedInputTransaction failure: \(error)",
                            logFunction: false)

                        serialQueue.async {
                            completion(.failure(.connectionError(error)))
                        }
                    }
                }
            case .failure(let error):
                logger.info(
                    "preparePresignedInputTransaction failure: \(error)",
                    logFunction: false)
                serialQueue.async {
                    completion(.failure(error))
                }
            }
        }

        func preparePresignedInputTransaction(
            presignedInput: SignedContingentInput,
            memoType: MemoType,
            feeLevel: FeeLevel,
            completion: @escaping (Result<PendingTransaction, TransactionPreparationError>)
            -> Void
        ) {
            let amountToSend = presignedInput.requiredAmount
            let amountToReceive = presignedInput.rewardAmount
            let feeTokenId = amountToReceive.tokenId

            metaFetcher.feeStrategy(for: feeLevel, tokenId: feeTokenId) {
                switch $0 {
                case .success(let feeStrategy):

                    let (unspentTxOuts, ledgerBlockCount) =
                        self.account.readSync {
                            ($0.unspentTxOuts(tokenId: amountToSend.tokenId),
                             $0.knowableBlockCount)
                        }

                    if ledgerBlockCount > presignedInput.tombstoneBlockIndex {
                        serialQueue.async {
                            completion(.failure(.invalidInput("Presigned Input Expired.")))
                        }
                        return
                    }

                    // calculate fee
                    //  1 input from SCI creator
                    //  1 input from SCI consumer
                    //  1 output to consumer for reward amount from SCI creator's TxIn
                    //  1 output (change) to return reward overage from creator's TxIn
                    //  1 output to creator for required amount from SCI consumer's TxIn
                    //  1 output (change) to consumer for overage from consumer's TxIn
                    let fee = feeStrategy.fee(numInputs: 2, numOutputs: 4)
                    if amountToReceive.value < fee {
                        serialQueue.async {
                            completion(.failure(.invalidInput("Reward Amount < Fee.")))
                        }
                        return
                    }

                    logger.info(
                        "Preparing pre-signed input transaction with fee level...feeLevel: " +
                            "\(feeLevel), unspentTxOutValues: " +
                            "\(redacting: unspentTxOuts.map { $0.value })",
                        logFunction: false)

                    switch self.txOutSelector
                        .selectTransactionInput(
                            amount: amountToSend,
                            feeStrategy: FixedFeeStrategy(fee: 0), // zero fee for SCI calculation
                            fromTxOuts: unspentTxOuts)
                        .mapError({ error -> TransactionPreparationError in
                            switch error {
                            case .insufficientTxOuts:
                                return .insufficientBalance()
                            case .defragmentationRequired:
                                return .defragmentationRequired()
                            }
                        })
                    {
                    case .success(let (inputs: inputs, fee: _ )):
                        metaFetcher.blockVersion {
                            switch $0 {
                            case .success(let blockVersion):
                                logger.info(
                                    "Transaction with presigned input prepared with fee level. " +
                                        "fee: \(redacting: fee)",
                                    logFunction: false)

                                let tombstoneBlockIndex =
                                    min(ledgerBlockCount + 50, presignedInput.tombstoneBlockIndex)

                                self.transactionPreparer.preparePresignedInputTransaction(
                                    presignedInput: presignedInput,
                                    inputs: inputs,
                                    memoType: memoType,
                                    amount: amountToSend,
                                    fee: Amount(fee, in: presignedInput.feeTokenId),
                                    tombstoneBlockIndex: tombstoneBlockIndex,
                                    blockVersion: blockVersion,
                                    completion: completion)
                            case .failure(let error):
                                logger.info(
                                    "preparePresignedInputTransaction failure: \(error)",
                                    logFunction: false)

                                serialQueue.async {
                                    completion(.failure(.connectionError(error)))
                                }
                            }
                        }
                    case .failure(let error):
                        logger.info(
                            "preparePresignedInputTransaction failure: \(error)",
                            logFunction: false)
                        serialQueue.async {
                            completion(.failure(error))
                        }
                    }
                case .failure(let connectionError):
                    logger.info("failure - error: \(connectionError)")
                    completion(.failure(.connectionError(connectionError)))
                }
            }
        }

    }
}
