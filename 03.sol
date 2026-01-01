// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
contract Test {
    string public storageVar = unicode"我在区块链上"; // 石碑
    
    function testMemory() public pure returns (string memory) {
        string memory memoryVar = unicode"我是临时的"; //  便签
        return memoryVar;
    }
    
    function testStorage() public view returns (string memory) {
        return storageVar; // 📝 从石碑抄到便签
    }
}
