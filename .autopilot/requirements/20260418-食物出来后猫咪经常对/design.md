## 设计文档

**目标**: 让 thinking/toolUse 状态的猫也能被食物吸引，实现"一群猫抢食物"的效果

**根因**: 三个独立门控只允许 idle 猫响应食物，但 GKState 层面 thinking/toolUse 都已允许转入 eating

**技术方案**: 打通三个门控 — BuddyScene.foodEligibleCats() + FoodManager 改用它 + MovementComponent.walkToFood 放宽 guard

**文件**: BuddyScene.swift, FoodManager.swift, MovementComponent.swift, CatConstants.swift
