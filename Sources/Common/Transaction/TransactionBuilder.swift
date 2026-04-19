//
//  Copyright (c) 2020-2021 MobileCoin. All rights reserved.
//

// swiftlint:disable function_default_parameter_at_end
// swiftlint:disable multiline_function_chains function_body_length

import Foundation
import LibMobileCoin
#if canImport(LibMobileCoinCommon)
import LibMobileCoinCommon
#endif

enum TransactionBuilderError: Error {
    case invalidInput(String)
    case invalidBlockVersion(String)
    case attestationVerificationFailed(String)
}

extension TransactionBuilderError: CustomStringConvertible {
    var description: String {
        "Transaction builder error: " + {
            switch self {
            case .invalidInput(let reason):
                return "Invalid input: \(reason)"
            case .invalidBlockVersion(let reason):
                return "Invalid Block Version: \(reason)"
            case .attestationVerificationFailed(let reason):
                return "Attestation verification failed: \(reason)"
            }
        }()
    }
}

final class TransactionBuilder {

    private let tombstoneBlockIndex: UInt64

    private let ptr: OpaquePointer

    private let memoBuilder: TxOutMemoBuilder

    struct Context {
        let accountKey: AccountKey
        let blockVersion: BlockVersion
        let fogResolver: FogResolver
        let memoType: MemoType
        let tombstoneBlockIndex: UInt64
        let fee: Amount
        let rngSeed: RngSeed
    }

    private struct InnerContext {
        let blockVersion: BlockVersion
        var fogResolver = FogResolver()
        var memoBuilder: TxOutMemoBuilder = DefaultMemoBuilder()
        let tombstoneBlockIndex: UInt64
        let fee: Amount
    }

    private init(
        context: InnerContext
    ) throws {
        self.tombstoneBlockIndex = context.tombstoneBlockIndex
        self.memoBuilder = context.memoBuilder
        let result: Result<OpaquePointer, TransactionBuilderError>
        result = memoBuilder.withUnsafeOpaquePointer { memoBuilderPtr in
            context.fogResolver.withUnsafeOpaquePointer { fogResolverPtr in
                // Safety: mc_transaction_builder_create should never return nil.
                withMcError { errorPtr in
                    mc_transaction_builder_create(
                        context.fee.value,
                        context.fee.tokenId.value,
                        context.tombstoneBlockIndex,
                        fogResolverPtr,
                        memoBuilderPtr,
                        context.blockVersion,
                        &errorPtr)
                }.mapError {
                    switch $0.errorCode {
                    case .invalidInput:
                        return .invalidInput("\(redacting: $0.description)")
                    default:
                        // Safety: mc_transaction_builder_add_input should not throw
                        // non-documented errors.
                        logger.fatalError("Unhandled LibMobileCoin error: \(redacting: $0)")
                    }
                }
            }
        }
        self.ptr = try result.get()
    }

    deinit {
        mc_transaction_builder_free(ptr)
    }
}

extension TransactionBuilder {
    static func build(
        context: TransactionBuilder.Context,
        inputs: [PreparedTxInput],
        to recipient: PublicAddress,
        amount: Amount
    ) -> Result<PendingSinglePayloadTransaction, TransactionBuilderError> {
        build(
            context: context,
            inputs: inputs,
            outputs: [TransactionOutput(recipient, amount)]
        ).map { pendingTransaction in
            pendingTransaction.singlePayload
        }
    }

    static func build(
        context: TransactionBuilder.Context,
        inputs: [PreparedTxInput],
        sendingAllTo recipient: PublicAddress
    ) -> Result<PendingSinglePayloadTransaction, TransactionBuilderError> {
        guard let tokenId = inputs.first?.knownTxOut.amount.tokenId else {
            return .failure(.invalidInput("No inputs to send"))
        }
        return Math.remainingAmount(
            inputValues: inputs.map { $0.knownTxOut.value },
            outputValues: [],
            fee: context.fee
        ).map { outputAmount in
            let amountToSend = Amount(outputAmount, in: tokenId)
            let changeAmount = Amount(0, in: tokenId)
            return PossibleTransaction([TransactionOutput(recipient, amountToSend)], changeAmount)
        }.flatMap { possibleTransaction in
            build(
                context: context,
                inputs: inputs,
                possibleTransaction: possibleTransaction,
                presignedInput: nil
            ).map { pendingTransaction in
                pendingTransaction.singlePayload
            }
        }
    }

    static func build(
        context: TransactionBuilder.Context,
        inputs: [PreparedTxInput],
        presignedInput: SignedContingentInput
    ) -> Result<PendingTransaction, TransactionBuilderError> {
        outputsAddingChangeOutputForSCI(
            inputs: inputs,
            presignedInput: presignedInput
        ).flatMap { buildingTransaction in
            build(
                context: context,
                inputs: inputs,
                possibleTransaction: buildingTransaction,
                presignedInput: presignedInput)
        }
    }

    static func build(
        context: TransactionBuilder.Context,
        inputs: [PreparedTxInput],
        outputs: [TransactionOutput]
    ) -> Result<PendingTransaction, TransactionBuilderError> {
        outputsAddingChangeOutput(
            inputs: inputs,
            outputs: outputs,
            fee: context.fee
        ).flatMap { buildingTransaction in
            build(
                context: context,
                inputs: inputs,
                possibleTransaction: buildingTransaction,
                presignedInput: nil)
        }
    }

    static func build(
        context: TransactionBuilder.Context,
        inputs: [PreparedTxInput],
        possibleTransaction: PossibleTransaction,
        presignedInput: SignedContingentInput? = nil
    ) -> Result<PendingTransaction, TransactionBuilderError> {
        guard Math.totalOutlayCheck(
                for: possibleTransaction,
                fee: context.fee,
                inputs: inputs,
                presignedInput: presignedInput
        ) else {
            return .failure(.invalidInput("Input values != output values + fee"))
        }

        let builder: TransactionBuilder
        do {
            builder = try TransactionBuilder(
                context: InnerContext(
                    blockVersion: context.blockVersion,
                    fogResolver: context.fogResolver,
                    memoBuilder: context.memoType.createMemoBuilder(accountKey: context.accountKey),
                    tombstoneBlockIndex: context.tombstoneBlockIndex,
                    fee: context.fee))
        } catch {
            guard let error = error as? TransactionBuilderError else {
                return .failure(.invalidInput("Unknown Error"))
            }
            return .failure(error)
        }

        for input in inputs {
            if case .failure(let error) =
                builder.addInput(preparedTxInput: input, accountKey: context.accountKey) {
                return .failure(error)
            }
        }

        let seededRng = MobileCoinChaCha20Rng(rngSeed: context.rngSeed)

        let payloadContexts = possibleTransaction.outputs.map { output in
            builder.addOutput(
                publicAddress: output.recipient,
                amount: output.amount,
                rng: seededRng
            )
        }

        let changeContext = changeContext(
            blockVersion: context.blockVersion,
            accountKey: context.accountKey,
            builder: builder,
            changeAmount: possibleTransaction.changeAmount,
            rng: seededRng)

        var presignedIncomeTxOutContexts = [TxOutContext]()
        if let presignedInput = presignedInput {
            // add SCI
            if case .failure(let error) =
                builder.addSignedContingentInput(signedContingentInput: presignedInput) {
                return .failure(error)
            }

            // net reward amount is reward amount minus fee
            _ = Math.positiveRemainingAmount(
                inputAmounts: [presignedInput.rewardAmount],
                fee: context.fee
            ).map { netRewardAmount in
                // add reward output from SCI
                builder.addOutput(
                    publicAddress: context.accountKey.publicAddress,
                    amount: netRewardAmount,
                    rng: seededRng
                ).map { incomeTxOutContext in
                    presignedIncomeTxOutContexts.append(incomeTxOutContext)
                }
            }
        }

        return payloadContexts.collectResult().flatMap { payloadContexts in
            changeContext.flatMap { changeContext in
                builder.build(rng: seededRng).map { transaction in
                    PendingTransaction(
                        transaction: transaction,
                        payloadTxOutContexts: payloadContexts,
                        changeTxOutContext: changeContext,
                        presignedInputIncomeTxOutContexts: presignedIncomeTxOutContexts)
                }
            }
        }
    }

    private static func changeContext(
        blockVersion: BlockVersion,
        accountKey: AccountKey,
        builder: TransactionBuilder,
        changeAmount: Amount,
        rng: MobileCoinRng
    ) -> Result<TxOutContext, TransactionBuilderError> {
        switch blockVersion {
        case .legacy:
            // Clients built for BlockVersion == 0 (.legacy) will have trouble finding txOuts
            // on the new change subaddress (max - 1), so we will emulate legacy behavior.
            return builder.addOutput(
                publicAddress: accountKey.publicAddress,
                amount: changeAmount,
                rng: rng)
        default:
            return builder.addChangeOutput(
                accountKey: accountKey,
                amount: changeAmount,
                rng: rng)
        }
    }

    static func output(
        publicAddress: PublicAddress,
        amount: Amount,
        fogResolver: FogResolver = FogResolver(),
        blockVersion: BlockVersion,
        rng: MobileCoinRng
    ) -> Result<TxOut, TransactionBuilderError> {
        outputWithReceipt(
            publicAddress: publicAddress,
            amount: amount,
            tombstoneBlockIndex: 0,
            fogResolver: fogResolver,
            blockVersion: blockVersion,
            rng: rng
        ).map { $0.txOut }
    }

    static func outputWithReceipt(
        publicAddress: PublicAddress,
        amount: Amount,
        tombstoneBlockIndex: UInt64,
        fogResolver: FogResolver = FogResolver(),
        blockVersion: BlockVersion,
        rng: MobileCoinRng
    ) -> Result<TxOutContext, TransactionBuilderError> {
        let transactionBuilder: TransactionBuilder
        do {
            transactionBuilder = try TransactionBuilder(
                context: InnerContext(blockVersion: blockVersion,
                                      fogResolver: fogResolver,
                                      tombstoneBlockIndex: tombstoneBlockIndex,
                                      fee: Amount(0, in: .MOB))
                )
        } catch {
            guard let error = error as? TransactionBuilderError else {
                return .failure(.invalidInput("Unknown Error"))
            }
            return .failure(error)
        }
        return transactionBuilder.addOutput(
            publicAddress: publicAddress,
            amount: amount,
            rng: rng)
    }

    private static func outputsAddingChangeOutput(
        inputs: [PreparedTxInput],
        outputs: [TransactionOutput],
        fee: Amount
    ) -> Result<PossibleTransaction, TransactionBuilderError> {
        Math.remainingAmount(
            inputValues: inputs.map { $0.knownTxOut.value },
            outputValues: outputs.map { $0.amount.value },
            fee: fee
        )
        .map { changeValue in
            if let posChangeValue = PositiveUInt64(changeValue) {
                return PossibleTransaction(outputs, Amount(posChangeValue.value, in: fee.tokenId))
            } else {
                return PossibleTransaction(outputs, Amount(0, in: fee.tokenId))
            }
        }
    }

    private static func outputsAddingChangeOutputForSCI(
        inputs: [PreparedTxInput],
        presignedInput: SignedContingentInput
    ) -> Result<PossibleTransaction, TransactionBuilderError> {

        let reqdAmt = presignedInput.requiredAmount

        // fee covered by sci reward amount
        let zeroFee = Amount(0, in: presignedInput.requiredAmount.tokenId)

        return Math.remainingAmount(
            inputValues: inputs.map { $0.knownTxOut.value },
            outputValues: [reqdAmt.value],
            fee: zeroFee
        )
        .map { changeValue in
            if let posChangeValue = PositiveUInt64(changeValue) {
                return PossibleTransaction([], Amount(posChangeValue.value, in: reqdAmt.tokenId))
            } else {
                return PossibleTransaction([], Amount(0, in: reqdAmt.tokenId))
            }
        }
    }

}

extension TransactionBuilder {
    private func addInput(preparedTxInput: PreparedTxInput, accountKey: AccountKey)
        -> Result<(), TransactionBuilderError>
    {
        let subaddressIndex = preparedTxInput.subaddressIndex
        guard let spendPrivateKey = accountKey.privateKeys(for: subaddressIndex)?.spendKey else {
            return .failure(.invalidInput("Tx subaddress index out of bounds"))
        }
        return addInput(
                preparedTxInput: preparedTxInput,
                viewPrivateKey: accountKey.viewPrivateKey,
                subaddressSpendPrivateKey: spendPrivateKey)
    }

    private func addInput(
        preparedTxInput: PreparedTxInput,
        viewPrivateKey: RistrettoPrivate,
        subaddressSpendPrivateKey: RistrettoPrivate
    ) -> Result<(), TransactionBuilderError> {
        TransactionBuilderUtils.addInput(
            ptr: ptr,
            preparedTxInput: preparedTxInput,
            viewPrivateKey: viewPrivateKey,
            subaddressSpendPrivateKey: subaddressSpendPrivateKey)
    }

    private func addOutput(
        publicAddress: PublicAddress,
        amount: Amount,
        rng: MobileCoinRng
    ) -> Result<TxOutContext, TransactionBuilderError> {
        TransactionBuilderUtils.addOutput(
            ptr: ptr,
            tombstoneBlockIndex: tombstoneBlockIndex,
            publicAddress: publicAddress,
            amount: amount,
            rng: rng)
    }

    private func addChangeOutput(
        accountKey: AccountKey,
        amount: Amount,
        rng: MobileCoinRng
    ) -> Result<TxOutContext, TransactionBuilderError> {
        TransactionBuilderUtils.addChangeOutput(
            ptr: ptr,
            tombstoneBlockIndex: tombstoneBlockIndex,
            accountKey: accountKey,
            amount: amount,
            rng: rng)
    }

    private func addSignedContingentInput(
        signedContingentInput: SignedContingentInput
    ) -> Result<(), TransactionBuilderError> {
        TransactionBuilderUtils.addSignedContingentInput(
            ptr: ptr,
            signedContingentInput: signedContingentInput)
    }

    private func addSignedContingentInputPartialFill(
        signedContingentInput: SignedContingentInput,
        sciChangeAmount: Amount
    ) -> Result<[Amount], TransactionBuilderError> {
        TransactionBuilderUtils.addSignedContingentInputPartialFill(
            ptr: ptr,
            signedContingentInput: signedContingentInput,
            sciChangeAmount: sciChangeAmount)
    }

    private func build(
        rng: MobileCoinRng
    ) -> Result<Transaction, TransactionBuilderError> {
        TransactionBuilderUtils.build(ptr: ptr, rng: rng)
    }
}

// MARK: - Partial-Fill Swap (MCIP-42)

extension TransactionBuilder {
    /// Build a partial-fill swap transaction (MCIP-42 taker side).
    ///
    /// Composition (the order matters — libmobilecoin's partial-fill C FFI adds the
    /// proportional COUNTER outputs to the maker and the BASE change to the maker; the
    /// Swift caller is responsible for the taker's BASE receive and COUNTER change):
    ///
    ///   1. taker's COUNTER inputs (`inputs`, all in the SCI's counter token)
    ///   2. taker's BASE receive output (`fillBaseAmount`, less fee if base==MOB)
    ///   3. SCI partial-fill input (`sciChangeBaseAmount` = SCI's unfilled remainder in BASE)
    ///   4. taker's COUNTER change output (= sum(inputs) - counterCost - feeIfCounterIsMOB)
    ///
    /// - Parameter inputs: taker's UTXOs in the SCI's COUNTER token. The token id is taken
    ///   from these inputs, NOT from `presignedInput.pseudoOutputAmount.tokenId` — for an
    ///   MCIP-42 partial-fill SCI, the pseudoOutput holds the BASE token, while the actual
    ///   COUNTER lives in `proto.txIn.inputRules.partialFillOutputs[0]` (which the Swift
    ///   wrapper does not unmask).
    /// - Parameter presignedInput: the partial-fill SCI from DEQS.
    /// - Parameter fillBaseAmount: base tokens taker wants to receive
    ///   (= floor(payCounter * partialFillMax / maxCounter)).
    /// - Parameter sciChangeBaseAmount: base tokens the SCI keeps unfilled
    ///   (= partialFillMax - fillBaseAmount).
    static func buildPartialFillSwap(
        context: TransactionBuilder.Context,
        inputs: [PreparedTxInput],
        presignedInput: SignedContingentInput,
        fillBaseAmount: Amount,
        sciChangeBaseAmount: Amount
    ) -> Result<PendingTransaction, TransactionBuilderError> {
        // The COUNTER token (what the taker pays) is the token of the taker's inputs.
        // We do NOT derive COUNTER from `presignedInput.pseudoOutputAmount.tokenId`:
        // for MCIP-42 partial-fill SCIs that field is the BASE token (maker's input UTXO).
        // The actual COUNTER lives in `proto.txIn.inputRules.partialFillOutputs[0]`,
        // which the Swift wrapper does not unmask; the caller supplies it via the
        // matched-token taker inputs (selected upstream from `payCounterAmount.tokenId`).
        guard let firstInput = inputs.first else {
            return .failure(.invalidInput("Partial-fill swap requires at least one taker input"))
        }
        let counterTokenId = firstInput.knownTxOut.amount.tokenId
        let baseTokenId = fillBaseAmount.tokenId
        let fee = context.fee

        guard fillBaseAmount.tokenId == sciChangeBaseAmount.tokenId else {
            return .failure(.invalidInput(
                "fillBaseAmount and sciChangeBaseAmount must share token id"))
        }
        guard fillBaseAmount.tokenId != counterTokenId else {
            return .failure(.invalidInput("BASE token id must differ from COUNTER token id"))
        }
        guard inputs.allSatisfy({ $0.knownTxOut.amount.tokenId == counterTokenId }) else {
            return .failure(.invalidInput("All inputs must be in SCI's counter token"))
        }

        let builder: TransactionBuilder
        do {
            builder = try TransactionBuilder(
                context: InnerContext(
                    blockVersion: context.blockVersion,
                    fogResolver: context.fogResolver,
                    memoBuilder: context.memoType.createMemoBuilder(
                        accountKey: context.accountKey),
                    tombstoneBlockIndex: context.tombstoneBlockIndex,
                    fee: fee))
        } catch {
            guard let e = error as? TransactionBuilderError else {
                return .failure(.invalidInput("Unknown Error"))
            }
            return .failure(e)
        }

        for input in inputs {
            if case .failure(let e) =
                builder.addInput(preparedTxInput: input, accountKey: context.accountKey) {
                return .failure(e)
            }
        }

        let seededRng = MobileCoinChaCha20Rng(rngSeed: context.rngSeed)

        // Taker's BASE receive. When base == fee token (counter==eUSD direction), the fee
        // is paid out of the SCI's pseudo input — deduct it from what the taker keeps so
        // the per-token MOB balance stays consistent.
        let takerBaseReceive: Amount
        if baseTokenId == fee.tokenId {
            guard fillBaseAmount.value > fee.value else {
                return .failure(.invalidInput(
                    "fillBaseAmount must exceed fee when base token == fee token"))
            }
            takerBaseReceive = Amount(fillBaseAmount.value - fee.value, in: baseTokenId)
        } else {
            takerBaseReceive = fillBaseAmount
        }

        let receiveResult = builder.addOutput(
            publicAddress: context.accountKey.publicAddress,
            amount: takerBaseReceive,
            rng: seededRng)

        // Add the partial-fill SCI. The C FFI internally appends the maker's proportional
        // counter outputs and the base change output; the returned [Amount] enumerates them
        // so the caller can compute the taker's counter change precisely.
        let scResult = builder.addSignedContingentInputPartialFill(
            signedContingentInput: presignedInput,
            sciChangeAmount: sciChangeBaseAmount)

        let counterOutlays: [Amount]
        switch scResult {
        case .success(let amounts): counterOutlays = amounts
        case .failure(let e): return .failure(e)
        }

        let counterCost = counterOutlays
            .filter { $0.tokenId == counterTokenId }
            .reduce(UInt64(0)) { $0 &+ $1.value }
        let inputSum = inputs.reduce(UInt64(0)) { $0 &+ $1.knownTxOut.value }
        let feeFromCounter: UInt64 = (counterTokenId == fee.tokenId) ? fee.value : 0

        guard inputSum >= counterCost,
              inputSum - counterCost >= feeFromCounter else {
            return .failure(.invalidInput(
                "Counter inputs (\(inputSum)) < counterCost (\(counterCost)) + " +
                "fee (\(feeFromCounter))"))
        }
        let counterChangeAmount = Amount(
            inputSum - counterCost - feeFromCounter, in: counterTokenId)

        let changeContextResult = builder.addChangeOutput(
            accountKey: context.accountKey,
            amount: counterChangeAmount,
            rng: seededRng)

        return receiveResult.flatMap { receiveContext in
            changeContextResult.flatMap { changeContext in
                builder.build(rng: seededRng).map { transaction in
                    PendingTransaction(
                        transaction: transaction,
                        payloadTxOutContexts: [receiveContext],
                        changeTxOutContext: changeContext,
                        presignedInputIncomeTxOutContexts: [])
                }
            }
        }
    }

    /// Build a partial-fill swap transaction (MCIP-42 taker side) that aggregates N SCIs
    /// atomically. One transaction consumes all `presignedInputs`; the taker pays a single
    /// summed counter amount and receives N base outputs.
    ///
    /// Composition matches the singular variant, fanned out per SCI:
    ///   1. taker's COUNTER inputs (all in the shared counter token)
    ///   2. for each SCI i in [0, N): taker's BASE receive output (`fillBaseAmounts[i]`,
    ///      less the SINGLE tx-level fee deducted from output 0 only when base == MOB)
    ///   3. for each SCI i: SCI partial-fill input (`sciChangeBaseAmounts[i]`)
    ///   4. taker's COUNTER change output
    ///
    /// All `presignedInputs` MUST share `(baseTokenId, counterTokenId)` — caller (DEQS query)
    /// already pre-filters, but a defensive guard is enforced here.
    static func buildPartialFillSwap(
        context: TransactionBuilder.Context,
        inputs: [PreparedTxInput],
        presignedInputs: [SignedContingentInput],
        fillBaseAmounts: [Amount],
        sciChangeBaseAmounts: [Amount]
    ) -> Result<PendingTransaction, TransactionBuilderError> {
        guard !presignedInputs.isEmpty else {
            return .failure(.invalidInput("Multi-SCI swap requires at least one SCI"))
        }
        guard presignedInputs.count == fillBaseAmounts.count,
              presignedInputs.count == sciChangeBaseAmounts.count else {
            return .failure(.invalidInput(
                "presignedInputs / fillBaseAmounts / sciChangeBaseAmounts count mismatch"))
        }
        guard let firstInput = inputs.first else {
            return .failure(.invalidInput("Partial-fill swap requires at least one taker input"))
        }
        let counterTokenId = firstInput.knownTxOut.amount.tokenId
        let baseTokenId = fillBaseAmounts[0].tokenId
        let fee = context.fee

        // Mixed-token guard: every SCI must agree on (base, counter).
        // Defense-in-depth — the caller's DEQS pre-filter already enforces this, but a
        // programmer bug bypassing the filter would otherwise corrupt the tx silently.
        for i in 0..<fillBaseAmounts.count {
            guard fillBaseAmounts[i].tokenId == baseTokenId,
                  sciChangeBaseAmounts[i].tokenId == baseTokenId else {
                return .failure(.invalidInput(
                    "All fillBaseAmounts and sciChangeBaseAmounts must share the same base token id"))
            }
        }
        guard baseTokenId != counterTokenId else {
            return .failure(.invalidInput("BASE token id must differ from COUNTER token id"))
        }
        guard inputs.allSatisfy({ $0.knownTxOut.amount.tokenId == counterTokenId }) else {
            return .failure(.invalidInput("All inputs must be in SCI's counter token"))
        }

        let builder: TransactionBuilder
        do {
            builder = try TransactionBuilder(
                context: InnerContext(
                    blockVersion: context.blockVersion,
                    fogResolver: context.fogResolver,
                    memoBuilder: context.memoType.createMemoBuilder(
                        accountKey: context.accountKey),
                    tombstoneBlockIndex: context.tombstoneBlockIndex,
                    fee: fee))
        } catch {
            guard let e = error as? TransactionBuilderError else {
                return .failure(.invalidInput("Unknown Error"))
            }
            return .failure(e)
        }

        for input in inputs {
            if case .failure(let e) =
                builder.addInput(preparedTxInput: input, accountKey: context.accountKey) {
                return .failure(e)
            }
        }

        // CRITICAL: single RNG instance reused across ALL output additions and SCI adds.
        // Re-seeding per SCI would produce identical commitment masks, and consensus
        // would reject the tx with duplicate blindings.
        let seededRng = MobileCoinChaCha20Rng(rngSeed: context.rngSeed)

        // Compute per-SCI taker BASE receive amounts. Single-tx fee deduction: when
        // base == fee token (counter==eUSD direction, base==MOB), subtract the entire
        // tx-level fee from the FIRST SCI's receive only — never per-SCI.
        var takerBaseReceives: [Amount] = []
        takerBaseReceives.reserveCapacity(fillBaseAmounts.count)
        if baseTokenId == fee.tokenId {
            guard fillBaseAmounts[0].value > fee.value else {
                return .failure(.invalidInput(
                    "fillBaseAmounts[0] must exceed fee when base token == fee token"))
            }
            takerBaseReceives.append(
                Amount(fillBaseAmounts[0].value - fee.value, in: baseTokenId))
            for i in 1..<fillBaseAmounts.count {
                takerBaseReceives.append(fillBaseAmounts[i])
            }
        } else {
            takerBaseReceives = fillBaseAmounts
        }

        var receiveContexts: [TxOutContext] = []
        receiveContexts.reserveCapacity(fillBaseAmounts.count)
        var counterCost: UInt64 = 0

        for i in 0..<presignedInputs.count {
            let receiveResult = builder.addOutput(
                publicAddress: context.accountKey.publicAddress,
                amount: takerBaseReceives[i],
                rng: seededRng)

            switch receiveResult {
            case .success(let ctx):
                receiveContexts.append(ctx)
            case .failure(let e):
                return .failure(e)
            }

            let scResult = builder.addSignedContingentInputPartialFill(
                signedContingentInput: presignedInputs[i],
                sciChangeAmount: sciChangeBaseAmounts[i])

            switch scResult {
            case .success(let amounts):
                let perSciCounterCost = amounts
                    .filter { $0.tokenId == counterTokenId }
                    .reduce(UInt64(0)) { $0 &+ $1.value }
                counterCost = counterCost &+ perSciCounterCost
            case .failure(let e):
                return .failure(e)
            }
        }

        let inputSum = inputs.reduce(UInt64(0)) { $0 &+ $1.knownTxOut.value }
        let feeFromCounter: UInt64 = (counterTokenId == fee.tokenId) ? fee.value : 0

        guard inputSum >= counterCost,
              inputSum - counterCost >= feeFromCounter else {
            return .failure(.invalidInput(
                "Counter inputs (\(inputSum)) < counterCost (\(counterCost)) + " +
                "fee (\(feeFromCounter))"))
        }
        let counterChangeAmount = Amount(
            inputSum - counterCost - feeFromCounter, in: counterTokenId)

        let changeContextResult = builder.addChangeOutput(
            accountKey: context.accountKey,
            amount: counterChangeAmount,
            rng: seededRng)

        return changeContextResult.flatMap { changeContext in
            builder.build(rng: seededRng).map { transaction in
                PendingTransaction(
                    transaction: transaction,
                    payloadTxOutContexts: receiveContexts,
                    changeTxOutContext: changeContext,
                    presignedInputIncomeTxOutContexts: [])
            }
        }
    }
}
