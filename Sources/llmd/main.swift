import Foundation

let code = await LLMDCommandLine.main(arguments: Array(CommandLine.arguments.dropFirst()))
exit(code)
