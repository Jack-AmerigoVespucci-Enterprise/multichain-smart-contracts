// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./AnycallProxyBase.sol";
import "../interfaces/IRetrySwapinAndExec.sol";
import "../interfaces/IUnderlying.sol";

interface ICurveAave {
    function coins(uint256 index) external view returns (address);

    function underlying_coins(uint256 index) external view returns (address);

    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);

    function exchange_underlying(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);
}

contract AnycallProxy_CurveAave is AnycallProxyBase {
    using SafeERC20 for IERC20;

    mapping(address => bool) public supportedPool;

    struct AnycallInfo {
        address pool;
        address receiver;
        bool is_exchange_underlying;
        uint256 deadline;
        int128 i;
        int128 j;
        uint256 min_dy;
    }

    event ExecFailed(address indexed token, uint256 amount, bytes data);

    constructor(
        address _mpc,
        address _caller,
        address[] memory pools
    ) AnycallProxyBase(_mpc, _caller) {
        for (uint256 i = 0; i < pools.length; i++) {
            supportedPool[pools[i]] = true;
        }
    }

    function encode_anycall_info(AnycallInfo calldata info)
        public
        pure
        returns (bytes memory)
    {
        return abi.encode(info);
    }

    function decode_anycall_info(bytes memory data)
        public
        pure
        returns (AnycallInfo memory)
    {
        return abi.decode(data, (AnycallInfo));
    }

    function addSupportedPools(address[] calldata pools) external onlyMPC {
        for (uint256 i = 0; i < pools.length; i++) {
            supportedPool[pools[i]] = true;
        }
    }

    function removeSupportedPools(address[] calldata pools) external onlyMPC {
        for (uint256 i = 0; i < pools.length; i++) {
            supportedPool[pools[i]] = false;
        }
    }

    // impl `IAnycallProxy` interface
    // Note: take care of the situation when do the business failed.
    function exec(
        address token,
        uint256 amount,
        bytes calldata data
    ) external onlyAuth returns (bool success, bytes memory result) {
        AnycallInfo memory info = decode_anycall_info(data);
        try this.execExchange(token, amount, info) returns (
            bool succ,
            bytes memory res
        ) {
            (success, result) = (succ, res);
        } catch {
            // process failure situation (eg. return token)
            IERC20(token).safeTransfer(info.receiver, amount);
            emit ExecFailed(token, amount, data);
        }
    }

    function execExchange(
        address token,
        uint256 amount,
        AnycallInfo calldata info
    ) external returns (bool success, bytes memory result) {
        require(msg.sender == address(this));
        require(info.deadline >= block.timestamp, "AnycallProxy: expired");
        require(supportedPool[info.pool], "AnycallProxy: unsupported pool");
        require(info.receiver != address(0), "AnycallProxy: zero receiver");

        ICurveAave pool = ICurveAave(info.pool);

        uint256 i = uint256(uint128(info.i));
        uint256 j = uint256(uint128(info.j));

        address srcToken;
        address recvToken;
        if (info.is_exchange_underlying) {
            srcToken = pool.underlying_coins(i);
            recvToken = pool.underlying_coins(j);
        } else {
            srcToken = pool.coins(i);
            recvToken = pool.coins(j);
        }
        require(token == srcToken, "AnycallProxy: source token mismatch");
        require(recvToken != address(0), "AnycallProxy: zero receive token");

        uint256 recvAmount;
        if (info.is_exchange_underlying) {
            recvAmount = pool.exchange_underlying(
                info.i,
                info.j,
                amount,
                info.min_dy
            );
        } else {
            recvAmount = pool.exchange(info.i, info.j, amount, info.min_dy);
        }

        IERC20(recvToken).safeTransfer(info.receiver, recvAmount);

        return (true, abi.encode(recvToken, recvAmount));
    }

    function retrySwapinAndExec(
        address router,
        string calldata swapID,
        SwapInfo calldata swapInfo,
        bytes calldata data,
        bool dontExec
    ) external {
        require(supportedCaller[router], "unsupported router");
        AnycallInfo memory info = decode_anycall_info(data);
        require(msg.sender == info.receiver, "forbid call retry");

        address _underlying = IUnderlying(swapInfo.token).underlying();
        require(_underlying != address(0), "zero underlying");
        uint256 old_balance = IERC20(_underlying).balanceOf(address(this));

        IRetrySwapinAndExec(router).retrySwapinAndExec(
            swapID,
            swapInfo,
            address(this),
            data,
            dontExec
        );

        if (dontExec) {
            // process don't exec situation (eg. return token)
            uint256 new_balance = IERC20(_underlying).balanceOf(address(this));
            require(
                new_balance >= old_balance &&
                    new_balance <= old_balance + swapInfo.amount,
                "balance check failed"
            );
            IERC20(_underlying).safeTransfer(
                info.receiver,
                new_balance - old_balance
            );
        }
    }
}
