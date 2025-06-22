// Make sure to add the Testing framework to your target in Xcode
// File > Add Package Dependencies... > apple/swift-testing
/*
@testable import Aagedal_VideoLoop_Converter_2_0
// import Testing

@Suite("FileNameProcessor Tests")
struct FileNameProcessorTests {
    
    @Test("Process file name with special characters")
    func specialCharacterHandling() throws {
        let testCases: [(input: String, expected: String)] = [
            ("Video with spaces.mp4", "Video_with_spaces"),
            ("Video-with-hyphens.mp4", "Video-with-hyphens"),
            ("Video_with_underscores.mp4", "Video_with_underscores"),
            ("Video!@#$%^&*()_+={}[]|:;\"'<>,.?/~`.mp4", "Video_____________________________"),
            ("Video with 😊 emoji.mp4", "Video_with_emoji"),
            ("Video with 123 numbers.mp4", "Video_with_123_numbers"),
            ("   Trim   spaces   .mp4", "Trim_spaces"),
            ("..parent/path/../file.mp4", "..parent_path_.._file")
        ]
        
        for testCase in testCases {
            let result = FileNameProcessor.processFileName(testCase.input)
            #expect(result == testCase.expected,
                   "Input: \(testCase.input) -> Expected: \(testCase.expected), but got: \(result)")
        }
    }
    
    @Test("Handle empty input")
    func emptyInput() {
        let result = FileNameProcessor.processFileName("")
        #expect(result.isEmpty)
    }
    
    @Test("Handle only special characters")
    func onlySpecialCharacters() {
        let result = FileNameProcessor.processFileName("!@#$%^")
        #expect(result.isEmpty)
    }
    
    @Test("Handle multiple dots in filename")
    func multipleDots() {
        let result = FileNameProcessor.processFileName("file.name.with.dots.mp4")
        #expect(result == "file_name_with_dots")
    }
}
*/
