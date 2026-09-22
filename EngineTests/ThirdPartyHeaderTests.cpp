// Proves the vendored single headers compile in the engine's C++20 configuration.

#include <doctest.h>
#include <json.hpp>

#include <string>

TEST_CASE("nlohmann::json parses, edits and round-trips") {
    auto doc = nlohmann::json::parse(R"({"schemaVersion":1,"tracks":[{"kind":"video"},{"kind":"audio"}]})");
    CHECK(doc["schemaVersion"].get<int>() == 1);
    REQUIRE(doc["tracks"].size() == 2);
    CHECK(doc["tracks"][1]["kind"].get<std::string>() == "audio");

    doc["name"] = "Untitled";
    const auto reparsed = nlohmann::json::parse(doc.dump());
    CHECK(reparsed == doc);
    CHECK(reparsed.at("name") == "Untitled");
}

TEST_CASE("nlohmann::json reports malformed input without crashing") {
    nlohmann::json doc;
    CHECK_THROWS_AS(doc = nlohmann::json::parse("{not json"), nlohmann::json::parse_error);
    CHECK(doc.is_null());
    CHECK(nlohmann::json::accept("[1,2,3]"));
    CHECK_FALSE(nlohmann::json::accept("[1,2,"));
}
