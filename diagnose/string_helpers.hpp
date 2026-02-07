#pragma once

#include <cstddef>
#include <cstring>
#include <memory>
#include <vector>
#include <string>
#include <string_view>
#include <unordered_set>
#include <stdexcept>
#include <cstdint>
#include <algorithm>

namespace diagnose {

	inline std::vector<std::string_view> split(std::string_view str, char delimiter) {
	    std::vector<std::string_view> result;

	    size_t start = 0;
	    while (true) {
	        size_t pos = str.find(delimiter, start);
	        if (pos == std::string_view::npos) {
	            result.emplace_back(str.substr(start));
	            break;
	        }
	        result.emplace_back(str.substr(start, pos - start));
	        start = pos + 1;
	    }

	    return result;
	}

}
