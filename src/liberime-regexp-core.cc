#include <algorithm>
#include <exception>
#include <limits>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <rime/algo/syllabifier.h>
#include <rime/dict/dictionary.h>
#include <rime/schema.h>
#include <rime/ticket.h>

#include "emacs-module.h"

int plugin_is_GPL_compatible;

namespace {

using DictionaryCache =
    std::map<std::pair<std::string, std::string>,
             std::unique_ptr<rime::Dictionary>>;

DictionaryCache dictionaries;

std::string get_string(emacs_env *env, emacs_value value) {
  ptrdiff_t size = 0;
  env->copy_string_contents(env, value, nullptr, &size);
  std::string result(size - 1, '\0');
  env->copy_string_contents(env, value, result.data(), &size);
  return result;
}

emacs_value vector(emacs_env *env, const std::vector<emacs_value> &values) {
  return env->funcall(env, env->intern(env, "vector"), values.size(),
                      const_cast<emacs_value *>(values.data()));
}

emacs_value signal_error(emacs_env *env, const std::string &message) {
  emacs_value text = env->make_string(env, message.data(), message.size());
  emacs_value data[] = {text};
  env->non_local_exit_signal(
      env, env->intern(env, "error"),
      env->funcall(env, env->intern(env, "list"), 1, data));
  return env->intern(env, "nil");
}

std::vector<size_t> utf8_boundaries(const std::string &text) {
  std::vector<size_t> result = {0};
  for (size_t index = 0; index < text.size();) {
    unsigned char byte = text[index];
    index += byte < 0x80 ? 1 : byte < 0xe0 ? 2 : byte < 0xf0 ? 3 : 4;
    result.push_back(index);
  }
  return result;
}

std::vector<std::string> split_code(const std::string &code) {
  std::vector<std::string> result;
  size_t beginning = 0;
  while (beginning <= code.size()) {
    size_t end = code.find('\'', beginning);
    if (end == std::string::npos)
      end = code.size();
    if (end > beginning)
      result.push_back(code.substr(beginning, end - beginning));
    if (end == code.size())
      break;
    beginning = end + 1;
  }
  return result;
}

rime::Dictionary *get_dictionary(const std::string &schema_id,
                                 const std::string &name_space) {
  auto key = std::make_pair(schema_id, name_space);
  auto found = dictionaries.find(key);
  if (found != dictionaries.end())
    return found->second.get();

  auto *component = dynamic_cast<rime::DictionaryComponent *>(
      rime::Dictionary::Require("dictionary"));
  if (!component)
    return nullptr;
  rime::Schema schema(schema_id);
  rime::Ticket ticket(&schema, name_space);
  std::unique_ptr<rime::Dictionary> dictionary(component->Create(ticket));
  if (!dictionary || !dictionary->Load())
    return nullptr;
  auto *result = dictionary.get();
  dictionaries.emplace(std::move(key), std::move(dictionary));
  return result;
}

void add_edges(rime::Dictionary *dictionary, const std::string &text,
               const std::vector<size_t> &text_offsets,
               const std::string &code, size_t max_word_length,
               std::map<std::pair<size_t, size_t>, double> *edges) {
  const auto syllables = split_code(code);
  const size_t character_count = text_offsets.size() - 1;
  if (syllables.size() != character_count)
    return;
  std::string input;
  std::vector<size_t> code_offsets = {0};
  for (const auto &syllable : syllables) {
    input += syllable;
    code_offsets.push_back(input.size());
  }
  rime::SyllableGraph graph;
  rime::Syllabifier syllabifier(" '", false, true);
  if (syllabifier.BuildSyllableGraph(input, *dictionary->prism(), &graph) <= 0)
    return;

  for (size_t beginning = 0; beginning < character_count; ++beginning) {
    auto collector = dictionary->Lookup(graph, code_offsets[beginning]);
    if (!collector)
      continue;
    for (auto &[code_end, iterator] : *collector) {
      auto found = std::lower_bound(code_offsets.begin(), code_offsets.end(),
                                    code_end);
      if (found == code_offsets.end() || *found != code_end)
        continue;
      size_t end = found - code_offsets.begin();
      if (end <= beginning + 1 || end - beginning > max_word_length)
        continue;
      std::string expected =
          text.substr(text_offsets[beginning],
                      text_offsets[end] - text_offsets[beginning]);
      while (!iterator.exhausted()) {
        auto entry = iterator.Peek();
        if (entry && entry->text == expected) {
          auto key = std::make_pair(beginning, end);
          auto old = edges->find(key);
          if (old == edges->end() || entry->weight > old->second)
            (*edges)[key] = entry->weight;
          break;
        }
        if (!iterator.Next())
          break;
      }
    }
  }
}

emacs_value segment_han(emacs_env *env, ptrdiff_t nargs, emacs_value args[],
                        void *) noexcept {
  try {
    const std::string schema_id = get_string(env, args[0]);
    const std::string name_space = get_string(env, args[1]);
    const std::string text = get_string(env, args[2]);
    const size_t max_word_length =
        std::max<intmax_t>(1, env->extract_integer(env, args[4]));
    const double single_weight = env->extract_float(env, args[5]);
    const auto text_offsets = utf8_boundaries(text);
    const size_t character_count = text_offsets.size() - 1;

    rime::Dictionary *dictionary = get_dictionary(schema_id, name_space);
    if (!dictionary)
      return signal_error(env, "Could not load the Rime dictionary");

    std::map<std::pair<size_t, size_t>, double> edges;
    ptrdiff_t code_count = env->vec_size(env, args[3]);
    for (ptrdiff_t index = 0; index < code_count; ++index) {
      add_edges(dictionary, text, text_offsets,
                get_string(env, env->vec_get(env, args[3], index)),
                max_word_length, &edges);
    }
    for (size_t index = 0; index < character_count; ++index)
      edges[{index, index + 1}] = single_weight;

    const double negative_infinity =
        -std::numeric_limits<double>::infinity();
    std::vector<double> scores(character_count + 1, negative_infinity);
    std::vector<size_t> previous(character_count + 1, character_count + 1);
    scores[0] = 0.0;
    for (size_t beginning = 0; beginning < character_count; ++beginning) {
      auto edge = edges.lower_bound({beginning, 0});
      while (edge != edges.end() && edge->first.first == beginning) {
        size_t end = edge->first.second;
        double candidate = scores[beginning] + edge->second;
        if (candidate > scores[end] ||
            (candidate == scores[end] &&
             beginning < previous[end])) {
          scores[end] = candidate;
          previous[end] = beginning;
        }
        ++edge;
      }
    }

    std::vector<std::pair<size_t, size_t>> bounds;
    for (size_t end = character_count; end > 0;) {
      size_t beginning = previous[end];
      if (beginning > end)
        return signal_error(env, "Rime dictionary word graph is disconnected");
      bounds.emplace_back(beginning, end);
      end = beginning;
    }
    std::reverse(bounds.begin(), bounds.end());
    std::vector<emacs_value> result;
    result.reserve(bounds.size());
    for (const auto &[beginning, end] : bounds)
      result.push_back(vector(env, {env->make_integer(env, beginning),
                                    env->make_integer(env, end)}));
    return vector(env, result);
  } catch (const std::exception &error) {
    return signal_error(env, error.what());
  }
}

emacs_value clear_cache(emacs_env *env, ptrdiff_t, emacs_value[],
                        void *) noexcept {
  dictionaries.clear();
  return env->intern(env, "nil");
}

void define(emacs_env *env, const char *name, ptrdiff_t minimum,
            ptrdiff_t maximum,
            emacs_value (*function)(emacs_env *, ptrdiff_t, emacs_value[],
                                    void *) noexcept,
            const char *documentation) {
  emacs_value symbol = env->intern(env, name);
  emacs_value value = env->make_function(env, minimum, maximum, function,
                                         documentation, nullptr);
  emacs_value args[] = {symbol, value};
  env->funcall(env, env->intern(env, "defalias"), 2, args);
}

}  // namespace

extern "C" int emacs_module_init(emacs_runtime *runtime) noexcept {
  emacs_env *env = runtime->get_environment(runtime);
  define(env, "liberime-regexp--native-segment-han", 6, 6, segment_han,
         "Return static-dictionary word bounds for Han TEXT and CODES.\n\n"
         "(fn SCHEMA-ID NAMESPACE TEXT CODES MAX-WORD-LENGTH "
         "SINGLE-WEIGHT)");
  define(env, "liberime-regexp--native-clear-cache", 0, 0, clear_cache,
         "Release cached native Dictionary objects.\n\n(fn)");
  emacs_value feature = env->intern(env, "liberime-regexp-core");
  env->funcall(env, env->intern(env, "provide"), 1, &feature);
  return 0;
}
