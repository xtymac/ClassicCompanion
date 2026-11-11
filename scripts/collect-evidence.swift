import Foundation
// 用法：swift scripts/collect-evidence.swift [measure]   触发 Classic Companion 采集脱敏证据并写入报告文件
let obj: String? = CommandLine.arguments.dropFirst().first
DistributedNotificationCenter.default().postNotificationName(.init("local.classiccompanion.collectEvidence"), object: obj, userInfo: nil, deliverImmediately: true)
