// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.2 <0.9.0;

// 定义回调接口（ITokenRecipient）类似于格式要求，只约定规则，不实现具体功能，「谁转的代币（from）」、「转了多少代币（amount）」
interface ITokenRecipient {
    //函数名、参数、可见性（external）
    function onTransferReceived(address from, uint256 amount) external;
}

//我们要打造一个 “智能快递员”，功能是：「先把快递送到收件人门口（转账代币）→ 检查收件人是不是 “小区物业（合约地址）”→ 
//若是物业，就给物业前台打电话说 “XX 业主的快递到了，收件人 XX，物品重量 XX”（触发回调）→ 若不是物业（普通住户，EOA 地址），就直接放门口，不打电话」。
//「SmartToken 合约」就是这个 “智能快递员”

// 普通ERC20
contract SmartToken {
    // ERC20代币的基础信息（状态变量）
    string public name = "SmartBankToken"; // 代币名称
    string public symbol = "SBT"; // 代币符号
    uint8 public decimals = 18; // 代币小数位数（默认18，和ETH一致）
    uint256 public totalSupply; // 代币总供应量

    // 记录每个地址的代币余额
    mapping(address => uint256) public balanceOf;

    // 构造函数：初始化代币总供应量，全部发放给合约部署者（管理员）
    constructor(uint256 initialSupply) {
        // 因为decimals=18，所以要把初始供应量放大10^18倍（避免小数）
        totalSupply = initialSupply * (10 ** uint256(decimals));
        // 部署者的余额 = 总供应量
        balanceOf[msg.sender] = totalSupply;
    }

    // 普通transfer函数：实现代币转账（核心ERC20功能）
    function transfer(address to, uint256 value) public returns (bool success) {
        // 检查1：转账者的余额≥转账金额
        require(balanceOf[msg.sender] >= value, "Insufficient token balance");
        // 检查2：接收方地址不是0地址（避免代币丢失）
        require(to != address(0), "Cannot transfer to zero address");

        // 扣减转账者的余额
        balanceOf[msg.sender] -= value;
        // 增加接收方的余额
        balanceOf[to] += value;
        // 标记转账成功
        success = true;
    }

    // 辅助函数isContract（判断地址是否是合约地址）
    function isContract(address addr) private view returns (bool) {
        // 利用底层汇编指令extcodesize，获取地址的合约代码大小
        uint256 codeSize;
        assembly {
            // extcodesize(addr)：返回addr地址的合约代码字节数，无代码则返回0
            codeSize := extcodesize(addr)
        }
        // 代码大小>0 → 是合约地址；否则是EOA地址
        return codeSize > 0;
    }

    // 核心函数transferAndCall（转账+自动回调）
    function transferAndCall(address to, uint256 value) public returns (bool success) {
        // 步骤A：先执行普通transfer，完成代币转账（先送货）
        // 调用我们之前写的transfer函数，传入to和value
        success = transfer(to, value);
        // 确保转账成功后，再执行后续回调逻辑
        require(success, "Token transfer failed");

        // 步骤B：检测接收方是否是合约地址（判断收件人类型）
        if (isContract(to)) {
            // 步骤C：是合约地址，触发回调函数（打电话通知）
            // 把to地址转换成ITokenRecipient接口类型，才能调用onTransferReceived
            ITokenRecipient(to).onTransferReceived(msg.sender, value);
        }

        // 步骤D：不是合约地址，直接返回success（已在步骤A赋值为true）
        return success;
    }
}



contract Etherbank is ITokenRecipient{
   
   mapping (address => uint256) public balances;
   mapping (address => uint256) public tokenBalances;//用于存储用户代币余额
   mapping (address => uint256) public depositTimes; //最后一次存款 / 提款的时间戳

   address public owner;
   address[3] public topUsers;
   address public smartTokenAddress;

   bool public isPaused; //紧急暂停

   // 记录暂停/恢复操作（方便前端/链上查询操作记录）
   event ContractPaused(address indexed operator);
   event ContractUnpaused(address indexed operator);

   // 提前声明ETH提款和代币提款事件
   event EthWithdrawn(address indexed user, uint256 principal, uint256 interest, uint256 total);
   event TokenWithdrawn(address indexed user, uint256 tokenAmount);

   constructor() {
       owner = msg.sender;
       isPaused = false;
   }

   modifier onlyOwner() {
     require(owner == msg.sender , "Only owner can call this function");
     _;
   }

   //暂停检查修饰器
   modifier whenNotPaused() {
    require(!isPaused , "Contract is paused, operation not allowed");
    _;
   }

  function setSmartTokenAddress(address _tokenAddr) public onlyOwner {
        smartTokenAddress = _tokenAddr;
    }

   function withdraw(uint256 amount) public virtual onlyOwner whenNotPaused {

    // 边界检查（无存款记录禁止提款）
     uint256 userLastDepositTime = depositTimes[msg.sender]; // 获取用户最后一次存款/提款时间
     require(userLastDepositTime > 0, "No deposit record, cannot withdraw"); // 无记录则报错

     //计算存款时长（秒→天）
    uint256 currentTime = block.timestamp; // 获取当前区块时间戳（秒）
    uint256 depositDurationSeconds = currentTime - userLastDepositTime; // 存款总时长（秒）
    uint256 depositDays = depositDurationSeconds / 86400; // 转换为天数（取整，不足1天=0）
    // 备注：86400=24*60*60，即一天的总秒数

    //计算应付利息
    uint256 userBalance = balances[msg.sender]; // 获取用户当前的ETH存款余额
    uint256 dailyRate = 1; // 日利率0.1%（对应1/1000，整数计算）
    uint256 interest = (userBalance * depositDays * dailyRate) / 1000; // 利息公式：余额×天数×利率÷1000
    // 备注：先乘后除，保证整数计算的精度，避免小数溢出

     require(amount > 0 , "Withdraw amount must be greater than 0");
     require(address(this).balance >= amount + interest, "Insufficient contract balance (include interest)");
    // 扣减用户ETH本金（原有逻辑只提款未扣减本金，会导致重复提款）
     require(balances[msg.sender] >= amount, "Insufficient personal ETH balance");
     balances[msg.sender] -= amount; // 扣减用户存入的ETH本金

     (bool success, ) = payable(owner).call{value: amount + interest}("");
     require(success, "Withdraw failed");

    //重置存款时间戳
    depositTimes[msg.sender] = block.timestamp;
    //提款完成后，把用户的depositTimes更新为当前时间，下次用户存款 / 提款时，会从这个新时间开始计算利息，避免重复计算本次提款前的时长
   
    // 触发ETH提款事件 
    emit EthWithdrawn(msg.sender, amount, interest, amount + interest);
   }

   // 新增：代币提款核心函数（用户提取存入的SBT代币） 
   function withdrawToken(uint256 tokenAmount) public whenNotPaused {
       // 检查1：提款金额>0
       require(tokenAmount > 0, "Token withdraw amount must be greater than 0");
       // 检查2：用户代币余额≥提款金额
       require(tokenBalances[msg.sender] >= tokenAmount, "Insufficient personal token balance");
       // 检查3：银行合约持有足够的SBT代币（避免代币不足无法转账）
       require(smartTokenAddress != address(0), "SmartToken address not set");
       SmartToken tokenContract = SmartToken(smartTokenAddress);
       require(tokenContract.balanceOf(address(this)) >= tokenAmount, "Insufficient contract token balance");

       // 步骤1：扣减用户在银行的代币余额记录
       tokenBalances[msg.sender] -= tokenAmount;
       // 步骤2：银行合约调用SBT的transfer函数，将代币转给用户
       bool transferSuccess = tokenContract.transfer(msg.sender, tokenAmount);
       require(transferSuccess, "Token transfer failed during withdrawal");

       // 步骤3：触发代币提款事件
       emit TokenWithdrawn(msg.sender, tokenAmount);
   }
   

   function deposit() public payable virtual whenNotPaused {
     require(msg.value > 0 , "Deposit amount must be greater than 0");
     balances[msg.sender] += msg.value;
    // 存款时，把用户的存款时间更新为当前区块时间
     depositTimes[msg.sender] = block.timestamp; 
     updatebank(msg.sender);
   }
   
      // 暂停函数：加重复检查，避免无意义操作
   function pauseContract() public onlyOwner {
     require(!isPaused, "Contract is already paused"); // 已暂停则报错
     isPaused = true;
     emit ContractPaused(msg.sender); // 触发事件，记录操作人
   }

    // 恢复函数：加重复检查
   function unpauseContract() public onlyOwner {
     require(isPaused, "Contract is already unpaused"); // 已恢复则报错
     isPaused = false;
     emit ContractUnpaused(msg.sender); // 触发事件
   }

   // 实现ITokenRecipient接口的回调函数（原有代码遗漏，导致代币存入后无法记账） 
   function onTransferReceived(address from, uint256 amount) external virtual override {
       require(amount > 0, "Token amount must be greater than 0");
       tokenBalances[from] += amount; // 自动更新用户代币余额，完成代币存入记账
   }


   receive() external payable { 
     deposit();
   }


   function updatebank (address user) private {
     
     bool found = false;
     uint256 foundIndex = 0; 

     for(uint i=0 ; i<3 ; i++){
       if(user == topUsers[i]){
        found = true;
        foundIndex = i;
        break;
       }
     }

     if(found){
      for(uint256 i=foundIndex ; i>0 ; i-- ){
        if (balances[topUsers[i]] > balances[topUsers[i-1]]){
          address temp = topUsers[i];
          topUsers[i] = topUsers[i-1];
          topUsers[i-1] = temp;
        }
        else {
          break;
        }
      }
     }
     else {

          if (topUsers[2] == address(0)) {

            if (topUsers[0] == address(0)) {
               topUsers[0] = user; // 全空时，用户直接当第一名
              } 

              else if (topUsers[1] == address(0)) {
                  topUsers[1] = user;
              } 
              
              else {
                  topUsers[2] = user;
              }
          } 
          // 情况2：top3已满，判断用户余额是否超过最低名
          else if (balances[user] > balances[topUsers[2]]) {
              // 挤掉最低名，把用户放到top3的最后一位
              topUsers[2] = user;
              for (uint i = 2; i > 0; i--) {
                  if (balances[topUsers[i]] > balances[topUsers[i-1]]) {
                      address temp = topUsers[i];
                      topUsers[i] = topUsers[i-1];
                      topUsers[i-1] = temp;
                  } else {
                      break;
                  }
              }
          }
      } 
   }

   function getTop3Users() public view returns (address[3] memory topAddresses, uint256[3] memory topBalances) {
    // 遍历topUsers数组，逐个赋值地址和余额
    for (uint i = 0; i < 3; i++) {
        topAddresses[i] = topUsers[i]; // 第i名的地址
        topBalances[i] = balances[topUsers[i]]; // 第i名的存款余额
    }
    // Solidity会自动返回这两个数组，无需额外return语句
   }

    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }
}


interface IBank {
  function withdraw(uint256 amount) external ;
}


contract BigBank is Etherbank, IBank{

  modifier minDeposit() {
    require(msg.value >= 0.001 ether, "minDeposit must >= 0.001 ether");
    _;
  }

  function deposit() public payable override minDeposit{
      super.deposit();
  }

  function transferOwnership(address newAdmin) public onlyOwner{
    
    require(newAdmin != address(0), "new admin cannot be zero address!!!!!!");
    owner = newAdmin;

  }

  function withdraw(uint256 amount) public override(IBank, Etherbank) onlyOwner {
      super.withdraw(amount);
  }


}

