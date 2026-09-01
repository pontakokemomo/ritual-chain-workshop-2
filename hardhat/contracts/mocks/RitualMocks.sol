// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RitualChain} from "../ritual/RitualChain.sol";

/**
 * Test-only stand-ins for the Ritual precompiles and system contracts.
 *
 * Every mock is deployed normally and then copied to its canonical address with
 * `vm.etch`, so `RitualPredict` reaches them through the exact same constants it uses
 * on chain and nothing in the contract under test knows it is being tested.
 *
 * `vm.etch` copies runtime code but not storage, so none of these mocks may rely on a
 * constructor or an inline initialiser — the etched copy always starts blank and every
 * test configures it explicitly.
 *
 * The precompiles are reached with a raw `call` / `staticcall`, not through a function
 * selector, so they are implemented as `fallback` functions. A `fallback` that returns
 * `bytes memory` returns those bytes verbatim rather than ABI-wrapping them, which is
 * what makes them indistinguishable from a real precompile.
 */

// ──────────────────────────────── Scheduler ──────────────────────────────────

/// Records what was booked and replays it on demand, including the calldata rewrite
/// the real Scheduler performs.
contract MockScheduler {
    struct Call {
        address to;
        address caller;
        bytes data;
        uint32 gas;
        uint32 startBlock;
        uint32 numCalls;
        uint32 frequency;
        uint32 ttl;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        uint256 value;
        address payer;
        uint8 state; // 0 SCHEDULED, 1 EXECUTING, 2 COMPLETED, 3 CANCELLED, 4 EXPIRED
    }

    uint256 public callCount;
    mapping(uint256 => Call) private _calls;
    mapping(address => mapping(address => bool)) public approved;

    /// Lets a test prove that a resolution survives a Scheduler that refuses `cancel`.
    bool public rejectCancel;

    function setRejectCancel(bool v) external {
        rejectCancel = v;
    }

    function approveScheduler(address schedulerContract) external {
        approved[msg.sender][schedulerContract] = true;
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
        callId = ++callCount;
        Call storage c = _calls[callId];
        c.to = msg.sender; // the real Scheduler always calls back msg.sender
        c.caller = msg.sender;
        c.data = data;
        c.gas = gas;
        c.startBlock = startBlock;
        c.numCalls = numCalls;
        c.frequency = frequency;
        c.ttl = ttl;
        c.maxFeePerGas = maxFeePerGas;
        c.maxPriorityFeePerGas = maxPriorityFeePerGas;
        c.value = value;
        c.payer = payer;
    }

    function cancel(uint256 callId) external {
        require(!rejectCancel, "mock: cancel refused");
        require(_calls[callId].caller == msg.sender, "mock: not your call");
        _calls[callId].state = 3;
    }

    function getCallState(uint256 callId) external view returns (uint8) {
        return _calls[callId].state;
    }

    function getCall(uint256 callId) external view returns (Call memory) {
        return _calls[callId];
    }

    /**
     * Fire one booked execution exactly the way the chain does: overwrite calldata
     * bytes 4-35 with the execution index, then call back the contract that scheduled
     * it. `msg.sender` in the callback is this mock, which is etched at the canonical
     * Scheduler address, so the authorisation check sees the real thing.
     *
     * Reverts are bubbled up so a test can assert on them.
     */
    function fire(uint256 callId, uint256 executionIndex) external {
        Call storage c = _calls[callId];
        require(c.to != address(0), "mock: no such call");

        bytes memory data = c.data;
        require(data.length >= 36, "mock: callback data too short");
        assembly {
            // data + 32 is the selector, so data + 36 is the first argument word.
            mstore(add(data, 36), executionIndex)
        }

        (bool ok, bytes memory ret) = c.to.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

// ────────────────────────────── HTTP precompile ──────────────────────────────

contract MockHttpPrecompile {
    enum Mode {
        Ok, // a settled envelope carrying the configured response
        Unsettled, // simulation pass: actualOutput is still empty
        Garbage, // envelope decodes, but the payload inside it does not
        NotAnEnvelope, // returndata that is not (bytes, bytes) at all
        Fail // the precompile call itself fails
    }

    Mode public mode;
    uint16 public status;
    bytes public body;
    string public errorMessage;

    // Last request seen, so tests can assert on what was actually sent.
    uint256 public callCount;
    address public lastExecutor;
    uint256 public lastTtl;
    string public lastUrl;
    uint8 public lastMethod;

    function setMode(Mode m) external {
        mode = m;
    }

    function setResponse(
        uint16 status_,
        bytes calldata body_,
        string calldata errorMessage_
    ) external {
        mode = Mode.Ok;
        status = status_;
        body = body_;
        errorMessage = errorMessage_;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        // Decode the prefix of the 13-field request we care about. Decoding a prefix is
        // valid because the tuple heads sit at fixed offsets from the start.
        (
            address executor,
            ,
            uint256 ttl,
            ,
            ,
            string memory url,
            uint8 method
        ) = abi.decode(
                input,
                (address, bytes[], uint256, bytes[], bytes, string, uint8)
            );

        callCount += 1;
        lastExecutor = executor;
        lastTtl = ttl;
        lastUrl = url;
        lastMethod = method;

        if (mode == Mode.Fail) revert("mock: http precompile failure");
        if (mode == Mode.NotAnEnvelope) return hex"01";
        if (mode == Mode.Unsettled) return abi.encode(input, bytes(""));
        if (mode == Mode.Garbage) return abi.encode(input, hex"deadbeef");

        bytes memory settled = abi.encode(
            status,
            new string[](0),
            new string[](0),
            body,
            errorMessage
        );
        return abi.encode(input, settled);
    }
}

// ─────────────────────────────── jq precompile ───────────────────────────────

/// Keyed on the (query, json) pair, so a test only gets a value back if the jsonPath
/// and the HTTP body both arrived intact. Reached by `staticcall`, so the fallback
/// never writes.
contract MockJqPrecompile {
    enum Mode {
        Lookup, // answer from the configured table
        Empty, // return nothing (a real jq does this on a wrong outputType)
        Short, // return fewer than 32 bytes
        Fail // the staticcall itself fails
    }

    Mode public mode;
    mapping(bytes32 => uint256) private _values;
    mapping(bytes32 => bool) private _known;

    function setMode(Mode m) external {
        mode = m;
    }

    function setResult(
        string calldata query,
        string calldata json,
        uint256 value
    ) external {
        bytes32 k = keccak256(abi.encode(query, json));
        _values[k] = value;
        _known[k] = true;
    }

    // Not marked `view`: Solidity forbids a view fallback. The EVM enforces it anyway
    // because RitualPredict reaches jq with `staticcall`, and nothing below writes.
    fallback(bytes calldata input) external returns (bytes memory) {
        if (mode == Mode.Fail) revert("mock: jq failure");
        if (mode == Mode.Empty) return bytes("");
        if (mode == Mode.Short) return hex"0102";

        (string memory query, string memory json, uint8 outputType) = abi.decode(
            input,
            (string, string, uint8)
        );
        if (outputType != RitualChain.JQ_OUT_UINT256) return bytes("");

        bytes32 k = keccak256(abi.encode(query, json));
        if (!_known[k]) return bytes(""); // no match: jq yielded nothing
        return abi.encode(_values[k]);
    }
}

// ───────────────────────────── TEE service registry ──────────────────────────

contract MockTeeServiceRegistry {
    enum Mode {
        Pick, // return one of the registered executors
        NotFound, // no healthy executor
        SeedEcho, // return address(uint160(seed)) so a test can observe the seed
        Fail // the registry call itself fails
    }

    Mode public mode;
    address[] private _executors;

    function setMode(Mode m) external {
        mode = m;
    }

    function addExecutor(address e) external {
        _executors.push(e);
    }

    function executorCount() external view returns (uint256) {
        return _executors.length;
    }

    function pickServiceByCapability(
        uint8 capability,
        bool checkValidity,
        uint256 seed,
        uint256 maxProbes
    ) external view returns (address teeAddress, bool found) {
        checkValidity; // silence unused-parameter warnings
        maxProbes;

        if (mode == Mode.Fail) revert("mock: registry unavailable");
        if (mode == Mode.SeedEcho) return (address(uint160(seed)), true);
        if (mode == Mode.NotFound) return (address(0), false);
        if (capability != RitualChain.CAPABILITY_HTTP_CALL)
            return (address(0), false);
        if (_executors.length == 0) return (address(0), false);

        return (_executors[seed % _executors.length], true);
    }
}

// ───────────────────────────────  RitualWallet  ──────────────────────────────

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
