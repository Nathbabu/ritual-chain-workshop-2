// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RitualChain} from "../ritual/RitualChain.sol";

// ─────────────────────────────────────────────────────────────────────────────
// MockScheduler
//
// Mimics IScheduler at RitualChain.SCHEDULER. Records schedule() calls so tests
// can inspect them, and lets tests trigger onScheduledResolve directly.
// ─────────────────────────────────────────────────────────────────────────────
contract MockScheduler {
    struct ScheduledCall {
        bytes   data;
        uint32  gas;
        uint32  startBlock;
        uint32  numCalls;
        uint32  frequency;
        uint32  ttl;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint256 value;
        address payer;
        bool    cancelled;
    }

    mapping(uint256 => ScheduledCall) public calls;
    uint256 public nextCallId = 1;

    bool public approvalReceived;

    function approveScheduler(address) external {
        approvalReceived = true;
    }

    function schedule(
        bytes calldata data,
        uint32 gas,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address payer
    ) external returns (uint256 callId) {
        callId = nextCallId++;
        calls[callId] = ScheduledCall({
            data: data,
            gas: gas,
            startBlock: startBlock,
            numCalls: numCalls,
            frequency: frequency,
            ttl: ttl,
            maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            value: value,
            payer: payer,
            cancelled: false
        });
    }

    function cancel(uint256 callId) external {
        calls[callId].cancelled = true;
    }

    function getCallState(uint256 callId) external view returns (uint8) {
        if (calls[callId].cancelled) return 2; // cancelled
        if (calls[callId].startBlock == 0) return 0; // unknown
        return 1; // active
    }

    /// Trigger the scheduled callback on a target contract, simulating the
    /// Scheduler at a particular execution index.
    function triggerResolve(
        address target,
        uint256 callId,
        uint256 executionIndex
    ) external {
        ScheduledCall storage c = calls[callId];
        // Overwrite bytes 4-35 with the real executionIndex (as uint256 big-endian).
        bytes memory d = c.data;
        bytes32 encoded = bytes32(executionIndex);
        for (uint256 i = 0; i < 32; i++) {
            d[4 + i] = encoded[i];
        }
        (bool ok,) = target.call(d);
        require(ok, "MockScheduler: callback reverted");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockRitualWallet
// ─────────────────────────────────────────────────────────────────────────────
contract MockRitualWallet {
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _lockUntil;

    function deposit(uint256 lockDuration) external payable {
        _balances[msg.sender] += msg.value;
        _lockUntil[msg.sender] = block.number + lockDuration;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function lockUntil(address account) external view returns (uint256) {
        return _lockUntil[account];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockTEEServiceRegistry
// ─────────────────────────────────────────────────────────────────────────────
contract MockTEEServiceRegistry {
    address public executor;
    bool    public executorFound = true;

    function setExecutor(address e, bool found) external {
        executor = e;
        executorFound = found;
    }

    function pickServiceByCapability(
        uint8,
        bool,
        uint256,
        uint256
    ) external view returns (address teeAddress, bool found) {
        return (executor, executorFound);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockHttpPrecompile
//
// Deployed at RitualChain.HTTP_PRECOMPILE (0x0801) by the test setUp via vm.etch.
// Returns a configurable pre-encoded short-running-async envelope:
//   (bytes simmedInput, bytes actualOutput)
// where actualOutput is abi.encode(status, headers, headerValues, body, errorMessage).
// ─────────────────────────────────────────────────────────────────────────────
contract MockHttpPrecompile {
    bytes private _response;
    bool  private _shouldFail;

    function setResponse(uint16 status, bytes memory body, string memory errorMsg) external {
        bytes memory actualOutput = abi.encode(
            status,
            new string[](0),
            new string[](0),
            body,
            errorMsg
        );
        _response = abi.encode(bytes(""), actualOutput); // simmedInput=empty, actualOutput=real
        _shouldFail = false;
    }

    function setFailure() external {
        _shouldFail = true;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        require(!_shouldFail, "MockHttp: forced failure");
        return _response;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockJqPrecompile
//
// Deployed at RitualChain.JQ_PRECOMPILE (0x0803). Returns a configured uint256.
// ─────────────────────────────────────────────────────────────────────────────
contract MockJqPrecompile {
    uint256 private _value;
    bool    private _shouldFail;

    function setValue(uint256 v) external {
        _value = v;
        _shouldFail = false;
    }

    function setFailure() external {
        _shouldFail = true;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        if (_shouldFail) return bytes("");
        return abi.encode(_value);
    }
}
