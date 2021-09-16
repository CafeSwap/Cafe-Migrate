import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./libraries/ICafeRouter01.sol";
import "./libraries/IUniswapV2Pair.sol";
import "./libraries/IVault.sol";
// SPDX-License-Identifier: MIT
// File: contracts/interfaces/ICafeRouter01.sol



contract MigrateCafeZap is Ownable, IZap {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    address private WNATIVE;
    mapping(address => mapping(address => address)) private tokenBridgeForRouter;
    mapping(address => bool) public isFeeOnTransfer;

    mapping (address => bool) public useNativeRouter;

    constructor(address _WNATIVE) public Ownable() {
       WNATIVE = _WNATIVE;
    }

    /* ========== External Functions ========== */

    receive() external payable {}


    function estimateZapInToken(address _from, address _to, address _router, uint _amt) public view override returns (uint256, uint256) {
        // get pairs for desired lp
        if (_from == IUniswapV2Pair(_to).token0() || _from == IUniswapV2Pair(_to).token1()) { // check if we already have one of the assets
            // if so, we're going to sell half of _from for the other token we need
            // figure out which token we need, and approve
            address other = _from == IUniswapV2Pair(_to).token0() ? IUniswapV2Pair(_to).token1() : IUniswapV2Pair(_to).token0();
            // calculate amount of _from to sell
            uint sellAmount = _amt.div(2);
            // execute swap
            uint otherAmount = _estimateSwap(_from, sellAmount, other, _router);
            if (_from == IUniswapV2Pair(_to).token0()) {
                return (sellAmount, otherAmount);
            } else {
                return (otherAmount, sellAmount);
            }
        } else {
            // go through native token for highest liquidity
            uint nativeAmount = _from == WNATIVE ? _amt : _estimateSwap(_from, _amt, WNATIVE, _router);
            if (WNATIVE == IUniswapV2Pair(_to).token0()) {
                return (nativeAmount.div(2), _estimateSwap(WNATIVE, nativeAmount.div(2), IUniswapV2Pair(_to).token1(), _router ));
            }
            if (WNATIVE == IUniswapV2Pair(_to).token1()) {
                return (_estimateSwap(WNATIVE, nativeAmount.div(2), IUniswapV2Pair(_to).token0(), _router ), nativeAmount.div(2));
            }
                return (_estimateSwap(WNATIVE, nativeAmount.div(2), IUniswapV2Pair(_to).token0(), _router ), _estimateSwap(WNATIVE, nativeAmount.div(2), IUniswapV2Pair(_to).token1(), _router));
        }
    }



    function zapAcross(address _from, uint amount, address _toRouter, address _recipient) external override {
        IERC20(_from).safeTransferFrom(msg.sender, address(this), amount);

        IUniswapV2Pair pair = IUniswapV2Pair(_from);
        _approveTokenIfNeeded(pair.token0(), _toRouter);
        _approveTokenIfNeeded(pair.token1(), _toRouter);

        IERC20(_from).safeTransfer(_from, amount);
        uint amt0;
        uint amt1;
        (amt0, amt1) = pair.burn(address(this));
        IUniswapV2Router01(_toRouter).addLiquidity(pair.token0(), pair.token1(), amt0, amt1, 0, 0, _recipient, block.timestamp);
    }






    /* ========== Private Functions ========== */

    function _approveTokenIfNeeded(address token, address router) private {
        if (IERC20(token).allowance(address(this), router) == 0) {
            IERC20(token).safeApprove(router, type(uint).max);
        }
    }
    function _estimateSwap(address _from, uint amount, address _to, address routerAddr) private view returns (uint) {
        IUniswapV2Router01 router = IUniswapV2Router01(routerAddr);

        address fromBridge = tokenBridgeForRouter[_from][routerAddr];
        address toBridge = tokenBridgeForRouter[_to][routerAddr];

        address[] memory path;

        if (fromBridge != address(0) && toBridge != address(0)) {
            if (fromBridge != toBridge) {
                path = new address[](5);
                path[0] = _from;
                path[1] = fromBridge;
                path[2] = WNATIVE;
                path[3] = toBridge;
                path[4] = _to;
            } else {
                path = new address[](3);
                path[0] = _from;
                path[1] = fromBridge;
                path[2] = _to;
            }
        } else if (fromBridge != address(0)) {
            if (fromBridge == _to) {
                path = new address[](2);
                path[0] = _from;
                path[1] = _to;
            }
            else if (_to == WNATIVE) {
                path = new address[](3);
                path[0] = _from;
                path[1] = fromBridge;
                path[2] = WNATIVE;
            } else {
                path = new address[](4);
                path[0] = _from;
                path[1] = fromBridge;
                path[2] = WNATIVE;
                path[3] = _to;
            }
        } else if (toBridge != address(0)) {
            if (_from == toBridge) {
                path = new address[](2);
                path[0] = _from;
                path[1] = _to;
            } else if (_from == WNATIVE) {
                path = new address[](3);
                path[0] = WNATIVE;
                path[1] = toBridge;
                path[2] = _to;
            }
            else {
                path = new address[](4);
                path[0] = _from;
                path[1] = WNATIVE;
                path[2] = toBridge;
                path[3] = _to;
            }
        } else if (_from == WNATIVE || _to == WNATIVE) {
            path = new address[](2);
            path[0] = _from;
            path[1] = _to;
        } else {
            // Go through WNative
            path = new address[](3);
            path[0] = _from;
            path[1] = WNATIVE;
            path[2] = _to;
        }

        uint[] memory amounts = router.getAmountsOut(amount, path);
        return amounts[amounts.length - 1];
    }


    /* ========== RESTRICTED FUNCTIONS ========== */

    function setTokenBridgeForRouter(address token, address router, address bridgeToken) external onlyOwner {
       tokenBridgeForRouter[token][router] = bridgeToken;
    }

    function withdraw(address token) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(address(this).balance);
            return;
        }

        IERC20(token).transfer(owner(), IERC20(token).balanceOf(address(this)));
    }

    function setUseNativeRouter(address router) external onlyOwner {
        useNativeRouter[router] = true;
    }

}