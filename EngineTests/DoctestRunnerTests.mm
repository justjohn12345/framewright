// Runs every doctest TEST_CASE linked into EngineTests (plain C++ model/edit tests)
// as a single XCTest, reporting each failed doctest assertion as an XCTest failure
// at its source location.
//
// A subset: set DOCTEST_TEST_CASE (and/or DOCTEST_TEST_CASE_EXCLUDE, DOCTEST_SUBCASE) in the test
// process's environment to a doctest filter (comma-separated, `*` wildcards). From xcodebuild, prefix
// it with TEST_RUNNER_, which xcodebuild strips before passing it on:
//   TEST_RUNNER_DOCTEST_TEST_CASE='*reverse*' xcodebuild ... -only-testing:EngineTests/DoctestRunnerTests test
// A filter that matches nothing fails the test (a mistyped filter would otherwise pass silently).

#define DOCTEST_CONFIG_IMPLEMENT
#define DOCTEST_CONFIG_NO_POSIX_SIGNALS
#include <doctest.h>

#import <XCTest/XCTest.h>

#include <cctype>
#include <cstdlib>
#include <mutex>
#include <string>
#include <vector>

namespace {

struct DoctestFailure {
    std::string file;
    int line;
    std::string message;
};

struct DoctestResults {
    std::mutex mutex;
    std::vector<DoctestFailure> failures;
    unsigned testCasesRun = 0;
    int assertsRun = 0;
    std::string currentTestCase;
};

DoctestResults gResults;

// Collects results; doctest's console reporter still prints its usual output.
class XCTestBridgeListener final : public doctest::IReporter {
  public:
    explicit XCTestBridgeListener(const doctest::ContextOptions &) {}

    void report_query(const doctest::QueryData &) override {}
    void test_run_start() override {}
    void test_run_end(const doctest::TestRunStats &stats) override {
        std::lock_guard<std::mutex> lock(gResults.mutex);
        gResults.testCasesRun = stats.numTestCasesPassingFilters;
        gResults.assertsRun = stats.numAsserts;
    }
    void test_case_start(const doctest::TestCaseData &data) override {
        std::lock_guard<std::mutex> lock(gResults.mutex);
        gResults.currentTestCase = data.m_name;
    }
    void test_case_reenter(const doctest::TestCaseData &) override {}
    void test_case_end(const doctest::CurrentTestCaseStats &) override {}
    void test_case_exception(const doctest::TestCaseException &e) override {
        std::lock_guard<std::mutex> lock(gResults.mutex);
        gResults.failures.push_back(
            {"", 0, gResults.currentTestCase + ": unexpected exception: " + e.error_string.c_str()});
    }
    void subcase_start(const doctest::SubcaseSignature &) override {}
    void subcase_end() override {}
    void log_assert(const doctest::AssertData &a) override {
        if (!a.m_failed) {
            return;
        }
        std::lock_guard<std::mutex> lock(gResults.mutex);
        std::string message = gResults.currentTestCase + ": " + a.m_expr;
        if (a.m_decomp.size() > 0) {
            message += " (" + std::string(a.m_decomp.c_str()) + ")";
        }
        if (a.m_threw) {
            message += " threw: " + std::string(a.m_exception.c_str());
        }
        gResults.failures.push_back({a.m_file, a.m_line, message});
    }
    void log_message(const doctest::MessageData &) override {}
    void test_case_skipped(const doctest::TestCaseData &) override {}
};

} // namespace

REGISTER_LISTENER("xctest-bridge", 1, XCTestBridgeListener);

@interface DoctestRunnerTests : XCTestCase
@end

@implementation DoctestRunnerTests

- (void)testAllDoctestCases {
    doctest::Context context;
    context.setOption("no-breaks", true);
    context.setOption("no-intro", true);
    // Optional filters from the environment (see the top of the file).
    NSMutableArray<NSString *> *filters = [NSMutableArray array];
    for (const char *option : {"test-case", "test-case-exclude", "subcase"}) {
        std::string variable = "DOCTEST_" + std::string(option);
        for (char &c : variable) {
            c = c == '-' ? '_' : static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
        }
        const char *value = std::getenv(variable.c_str());
        if (value != nullptr && value[0] != '\0') {
            context.setOption(option, value);
            [filters addObject:[NSString stringWithFormat:@"%s=%s", variable.c_str(), value]];
        }
    }
    if (filters.count > 0) {
        NSLog(@"DoctestRunnerTests: running the doctest cases matching %@", [filters componentsJoinedByString:@", "]);
    }
    const int result = context.run();

    std::lock_guard<std::mutex> lock(gResults.mutex);
    if (filters.count > 0) {
        XCTAssertGreaterThan(gResults.testCasesRun, 0u, @"no doctest test case matches %@",
                             [filters componentsJoinedByString:@", "]);
    } else {
        XCTAssertGreaterThan(gResults.testCasesRun, 0u, @"no doctest test cases were linked into EngineTests");
    }
    for (const DoctestFailure &failure : gResults.failures) {
        XCTSourceCodeLocation *location = [[XCTSourceCodeLocation alloc] initWithFilePath:@(failure.file.c_str())
                                                                               lineNumber:failure.line];
        XCTIssue *issue = [[XCTIssue alloc] initWithType:XCTIssueTypeAssertionFailure
                                      compactDescription:@(failure.message.c_str())
                                     detailedDescription:nil
                                       sourceCodeContext:[[XCTSourceCodeContext alloc] initWithLocation:location]
                                         associatedError:nil
                                             attachments:@[]];
        [self recordIssue:issue];
    }
    XCTAssertEqual(result, 0, @"doctest reported failures");
}

@end
