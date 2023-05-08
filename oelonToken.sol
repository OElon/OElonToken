// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./IUniswapV2Router02.sol";

contract OELON is ERC20Burnable, ERC20Capped, ERC20Pausable, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

address public marketingWallet;
address public liquidityPool;
address public rewardToken;
address public dogeToken;
address public token;

uint256 public liquidityPoolFee = 1;
uint256 public marketingFee = 2;
uint256 public rewardFee = 2;

uint256 public rewardInterval = 4 * 24 * 60 * 60 + 20 * 60;
uint256 public lastRewardTime;

mapping(address => uint256) public lastRewardClaim;
mapping(address => uint256) private _balanceOf;
address[] private holders;

IUniswapV2Router02 public immutable uniswapV2Router;

event RewardsDistributed(uint256 totalReward);

constructor(
    address _marketingWallet,
    address _liquidityPool,
    address _uniswapV2Router,
    address _rewardToken,
    address _dogeToken,
    address _token
)
    ERC20("OELON", "OEL")
    ERC20Capped(500000000 * 10**18)
{
    require(_marketingWallet != address(0), "OELON: invalid marketing wallet");
    require(_liquidityPool != address(0), "OELON: invalid liquidity pool");
    require(_uniswapV2Router != address(0), "OELON: invalid Uniswap V2 router");

    marketingWallet = _marketingWallet;
    liquidityPool = _liquidityPool;
    lastRewardTime = block.timestamp;
    rewardToken = _rewardToken;
    dogeToken = _dogeToken;
    token = _token;

    uniswapV2Router = IUniswapV2Router02(_uniswapV2Router);

    _approve(address(this), address(uniswapV2Router), type(uint256).max);
}

function balanceOf(address account) public view override returns (uint256) {
    return super.balanceOf(account);
}

function _mint(address account, uint256 amount) internal override(ERC20, ERC20Capped) {
    // delegate to the implementation in ERC20Capped
    super._mint(account, amount);
}

function getBalanceOf(address account) public view returns (uint256) {
    return super.balanceOf(account);
}

function SwapAndDistribute() public onlyOwner {
    address[] memory path = new address[](2);
    path[0] = uniswapV2Router.WETH();
    path[1] = dogeToken;

    uint256 rewardBalance = IERC20(rewardToken).balanceOf(address(this));
    // swap the reward tokens to Doge on Uniswap V2
    uniswapV2Router.swapExactTokensForTokens(
        rewardBalance,
        0,
        path,
        address(this),
        block.timestamp
    );

    uint256 dogeBalance = IERC20(dogeToken).balanceOf(address(this));
    // distribute the Doge tokens to all token holders
    uint256 totalSupply = balanceOf(address(this));
    for (uint256 i = 0; i < holders.length; i++) {
        address holder = holders[i];
        uint256 balance = balanceOf(holder);
        uint256 reward = balance.mul(dogeBalance).div(totalSupply);
        IERC20(dogeToken).transfer(holder, reward);
    }
}

function transfer(address to, uint256 amount) public override returns (bool) {
    // Ensure that the sender has enough tokens to transfer
    require(balanceOf(msg.sender) >= amount, "Insufficient balance");

    // Transfer the tokens from the sender to the recipient
    _transfer(msg.sender, to, amount);

    // Add the recipient to the list of token holders
    if (balanceOf(to) > 0 && !hasTokenHolder(to, holders)) {
        holders.push(to);
    }

    return true;
}


function transferFrom(address sender, address recipient, uint256 amount) public override whenNotPaused returns (bool) {
    _transferWithFees(sender, recipient, amount);
    _approve(sender, _msgSender(), allowance(sender, _msgSender()).sub(amount, "ERC20: transfer amount exceeds allowance"));
    return true;
}

function _transferWithFees(address sender, address recipient, uint256 amount) private {
    uint256 liquidityPoolAmount = amount.mul(liquidityPoolFee).div(100);
    uint256 marketingAmount = amount.mul(marketingFee).div(100);
    uint256 rewardAmount = amount.mul(rewardFee).div(100);

    _transfer(sender, liquidityPool, liquidityPoolAmount);
    _transfer(sender, marketingWallet, marketingAmount);
    _transfer(sender, address(this), rewardAmount);
    _transfer(sender, recipient, amount.sub(liquidityPoolAmount).sub(marketingAmount).sub(rewardAmount));

    if (block.timestamp >= lastRewardTime.add(rewardInterval)) {
        _distributeRewards();
    }
}

function getTokenHolders() public view returns (address[] memory) {
    address[] memory holdersList = new address[](holders.length);
    uint256 holderCount = 0;

    for (uint256 i = 0; i < holders.length; i++) {
        address holder = holders[i];
        if (balanceOf(holder) > 0) {
            holdersList[holderCount++] = holder;
        }
    }

    // Resize the holdersList array to remove any empty slots
    assembly {
        mstore(holdersList, holderCount)
    }

    return holdersList;
}

function hasTokenHolder(address holder, address[] memory holdersList) private pure returns (bool) {
    for (uint256 i = 0; i < holdersList.length; i++) {
        if (holdersList[i] == holder) {
            return true;
        }
    }
    return false;
}

function calculateReward(address holder) public view returns (uint256) {
    if (lastRewardTime == 0 || IERC20(dogeToken).balanceOf(address(this)) == 0) {
        return 0;
    }

    uint256 timeElapsed = block.timestamp.sub(lastRewardTime);
    uint256 rewardPerToken = IERC20(dogeToken).balanceOf(address(this)).div(balanceOf(address(this)));

    uint256 lastReward = lastRewardClaim[holder];
    uint256 unclaimedRewards = rewardPerToken.mul(balanceOf(holder)).sub(lastReward);

    if (timeElapsed > rewardInterval) {
        return unclaimedRewards.add(rewardPerToken.mul(balanceOf(holder)));
    }

    uint256 timeRemaining = rewardInterval.sub(timeElapsed);
    uint256 additionalReward = timeRemaining.mul(rewardPerToken).mul(balanceOf(holder)).div(rewardInterval);

    return unclaimedRewards.add(additionalReward);
}

function removeHolder(address holder) private {
    if (!hasTokenHolder(holder, holders)) {
        return;
    }

    uint256 indexToRemove = 0;
    for (uint256 i = 0; i < holders.length; i++) {
        if (holders[i] == holder) {
            indexToRemove = i;
            break;
        }
    }

    if (indexToRemove >= holders.length) {
        return;
    }

    for (uint256 i = indexToRemove; i < holders.length - 1; i++) {
        holders[i] = holders[i + 1];
    }

    holders.pop();
}

function _distributeRewards() private {
    uint256 totalReward = balanceOf(address(this));
    uint256 count = holders.length;

    for (uint256 i = 0; i < count; i++) {
        address holder = holders[i];
        uint256 holderReward = totalReward.mul(_balanceOf[holder]).div(totalSupply());
        uint256 holderBalance = _balanceOf[holder];
        _balanceOf[holder] = holderBalance.add(holderReward);

        totalReward = totalReward.sub(holderReward);
    }

    _balanceOf[address(this)] = totalReward;

    uint256 currentTime = block.timestamp;
    uint256 timeElapsed = currentTime.sub(lastRewardTime);

    if (timeElapsed >= rewardInterval) {
        lastRewardTime = currentTime;
        emit RewardsDistributed(totalReward);
    }
}

    function claimReward() external {
        require(balanceOf(msg.sender) > 0, "OELON: sender balance is 0");
        require(lastRewardClaim[msg.sender] + rewardInterval <= block.timestamp, "OELON: reward already claimed");

        uint256 holderBalance = balanceOf(msg.sender);
        uint256 holderReward = calculateReward(msg.sender);

        _balanceOf[msg.sender] = holderBalance.add(holderReward);
        lastRewardClaim[msg.sender] = block.timestamp;

        IERC20(rewardToken).safeTransfer(msg.sender, holderReward);

        if (holderBalance == 0) {
            removeHolder(msg.sender);
        }
    }


    function _approve(address spender, uint256 amount) internal {
        IERC20(token).approve(spender, amount);
    }

    function setMarketingWallet(address _marketingWallet) external onlyOwner {
        require(_marketingWallet != address(0), "OELON: invalid marketing wallet");
        marketingWallet = _marketingWallet;
    }

    function setLiquidityPool(address _liquidityPool) external onlyOwner {
        require(_liquidityPool != address(0), "OELON: invalid liquidity pool");
        liquidityPool = _liquidityPool;
    }

    function setFees(uint256 _liquidityPoolFee, uint256 _marketingFee, uint256 _rewardFee) external onlyOwner {
        require(_liquidityPoolFee.add(_marketingFee).add(_rewardFee) == 5, "OELON: invalid total fees");
        liquidityPoolFee = _liquidityPoolFee;
        marketingFee = _marketingFee;
        rewardFee = _rewardFee;
    }

    function setRewardInterval(uint256 _rewardInterval) external onlyOwner {
        require(_rewardInterval > 0, "OELON: invalid reward interval");
        rewardInterval = _rewardInterval;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Pausable) {
        super._beforeTokenTransfer(from, to, amount);
    }

    receive() external payable {}

    fallback() external payable {}

    }
