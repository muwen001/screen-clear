import Foundation

/// 允许 Result<_, String> 的 .failure 用法（错误信息以字符串传递）
extension String: @retroactive Error {}
