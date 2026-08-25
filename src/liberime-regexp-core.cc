#include <algorithm>
#include <cmath>
#include <cstring>
#include <exception>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include <rime/candidate.h>
#include <rime/context.h>
#include <rime/dict/dictionary.h>
#include <rime/dict/reverse_lookup_dictionary.h>
#include <rime/schema.h>
#include <rime/service.h>
#include <rime/ticket.h>
#include <rime_api.h>

#include "emacs-module.h"

int plugin_is_GPL_compatible;

namespace {

struct DictionaryBundle {
  std::unique_ptr<rime::Dictionary> dictionary;
  std::unique_ptr<rime::ReverseLookupDictionary> reverse;
  std::vector<std::unordered_map<std::string, rime::SyllableId>> syllable_ids;
};

using DictionaryCache = std::map<std::pair<std::string, std::string>,
                                 std::unique_ptr<DictionaryBundle>>;

DictionaryCache dictionaries;

struct Candidate {
  std::string text;
  std::string comment;
  bool has_comment;
};

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

emacs_value list(emacs_env *env, const std::vector<emacs_value> &values) {
  return env->funcall(env, env->intern(env, "list"), values.size(),
                      const_cast<emacs_value *>(values.data()));
}

emacs_value string(emacs_env *env, const std::string &value) {
  return env->make_string(env, value.data(), value.size());
}

emacs_value candidate_list(emacs_env *env,
                           const std::vector<Candidate> &candidates) {
  std::vector<emacs_value> values;
  values.reserve(candidates.size());
  for (const auto &candidate : candidates) {
    emacs_value value = string(env, candidate.text);
    if (candidate.has_comment) {
      emacs_value args[] = {value, env->intern(env, ":comment"),
                            string(env, candidate.comment)};
      value = env->funcall(env, env->intern(env, "propertize"), 3, args);
    }
    values.push_back(value);
  }
  return list(env, values);
}

emacs_value signal_error(emacs_env *env, const std::string &message) {
  emacs_value text = env->make_string(env, message.data(), message.size());
  emacs_value data[] = {text};
  env->non_local_exit_signal(
      env, env->intern(env, "error"),
      env->funcall(env, env->intern(env, "list"), 1, data));
  return env->intern(env, "nil");
}

bool selected_candidate_is_completion(RimeSessionId session_id) {
  auto session = rime::Service::instance().GetSession(session_id);
  if (!session || !session->context())
    return false;
  auto candidate = session->context()->GetSelectedCandidate();
  auto genuine = rime::Candidate::GetGenuineCandidate(candidate);
  return genuine && genuine->type() == "completion";
}

emacs_value query(emacs_env *env, ptrdiff_t nargs, emacs_value args[],
                  void *) noexcept {
  try {
    const auto session_id =
        static_cast<RimeSessionId>(env->extract_integer(env, args[0]));
    const std::string input = get_string(env, args[1]);
    const size_t limit =
        nargs >= 3 && env->is_not_nil(env, args[2])
            ? std::max<intmax_t>(0, env->extract_integer(env, args[2]))
            : 0;
    const RimeApi *api = rime_get_api();
    if (!api || !RIME_API_AVAILABLE(api, set_input))
      return env->intern(env, "nil");
    if (!api->find_session(session_id))
      return signal_error(env, "Cannot find the Rime session");
    api->clear_composition(session_id);
    if (!api->set_input(session_id, input.c_str()))
      return env->intern(env, "nil");

    std::string commit;
    bool has_commit = false;
    RIME_STRUCT(RimeCommit, rime_commit);
    if (api->get_commit(session_id, &rime_commit)) {
      if (rime_commit.text) {
        commit = rime_commit.text;
        has_commit = true;
      }
      api->free_commit(&rime_commit);
    }

    std::string remaining_input;
    bool has_remaining_input = false;
    if (const char *value = api->get_input(session_id)) {
      remaining_input = value;
      has_remaining_input = true;
    }

    size_t input_end = 0;
    RIME_STRUCT(RimeContext, initial_context);
    if (api->get_context(session_id, &initial_context)) {
      input_end = initial_context.composition.length;
      api->free_context(&initial_context);
    }

    std::vector<Candidate> full;
    std::vector<Candidate> prefix;
    std::string remainder;
    bool has_remainder = false;
    std::set<std::pair<int, int>> seen;
    size_t examined = 0;
    for (;;) {
      RIME_STRUCT(RimeContext, context);
      if (!api->get_context(session_id, &context))
        break;
      const int index = context.menu.highlighted_candidate_index;
      const int page = context.menu.page_no;
      if (index < 0 || index >= context.menu.num_candidates ||
          !seen.emplace(page, index).second) {
        api->free_context(&context);
        break;
      }

      const RimeCandidate &candidate = context.menu.candidates[index];
      Candidate value = {candidate.text ? candidate.text : "",
                         candidate.comment ? candidate.comment : "",
                         candidate.comment != nullptr};
      const bool completion = selected_candidate_is_completion(session_id);
      const size_t selection_end = context.composition.sel_end;
      const char *preedit = context.composition.preedit;
      // Search expansion is exact: predictive translator candidates must not
      // turn a prefix such as "exp" into "explain".
      if (!completion && selection_end == input_end) {
        full.push_back(std::move(value));
      } else if (!completion && preedit &&
                 selection_end < std::strlen(preedit)) {
        std::string rest(preedit + selection_end);
        if (!rest.empty()) {
          if (!has_remainder || rest.size() > remainder.size()) {
            remainder = std::move(rest);
            has_remainder = true;
            prefix.clear();
            prefix.push_back(std::move(value));
          } else if (rest == remainder) {
            prefix.push_back(std::move(value));
          }
        }
      }
      api->free_context(&context);

      ++examined;
      if ((limit > 0 && examined >= limit) ||
          !api->process_key(session_id, 0xff54, 0))
        break;
    }

    const emacs_value nil = env->intern(env, "nil");
    std::vector<emacs_value> result = {
        env->intern(env, ":commit"),
        has_commit ? string(env, commit) : nil,
        env->intern(env, ":full"),
        candidate_list(env, full),
        env->intern(env, ":prefix"),
        candidate_list(env, prefix),
        env->intern(env, ":remainder"),
        has_remainder ? string(env, remainder) : nil,
        env->intern(env, ":remaining-input"),
        has_remaining_input ? string(env, remaining_input) : nil,
        env->intern(env, ":regexp-code"),
        nil,
        env->intern(env, ":regexp"),
        nil,
    };
    return list(env, result);
  } catch (const std::exception &error) {
    return signal_error(env, error.what());
  }
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

std::vector<std::string> split_reverse_codes(const std::string &codes) {
  std::istringstream stream(codes);
  std::vector<std::string> result;
  for (std::string code; stream >> code;)
    result.push_back(std::move(code));
  return result;
}

DictionaryBundle *get_dictionary(const std::string &schema_id,
                                 const std::string &name_space) {
  auto key = std::make_pair(schema_id, name_space);
  auto found = dictionaries.find(key);
  if (found != dictionaries.end())
    return found->second.get();

  auto *dictionary_component = dynamic_cast<rime::DictionaryComponent *>(
      rime::Dictionary::Require("dictionary"));
  auto *reverse_component = rime::ReverseLookupDictionary::Require(
      "reverse_lookup_dictionary");
  if (!dictionary_component || !reverse_component)
    return nullptr;
  rime::Schema schema(schema_id);
  rime::Ticket ticket(&schema, name_space);
  auto bundle = std::make_unique<DictionaryBundle>();
  bundle->dictionary.reset(dictionary_component->Create(ticket));
  bundle->reverse.reset(reverse_component->Create(ticket));
  if (!bundle->dictionary || !bundle->dictionary->Load() ||
      !bundle->reverse || !bundle->reverse->Load())
    return nullptr;

  for (const auto &table : bundle->dictionary->tables()) {
    rime::Syllabary syllabary;
    if (!table->GetSyllabary(&syllabary))
      return nullptr;
    std::unordered_map<std::string, rime::SyllableId> ids;
    rime::SyllableId id = 0;
    for (const auto &syllable : syllabary)
      ids.emplace(syllable, id++);
    bundle->syllable_ids.push_back(std::move(ids));
  }

  auto *result = bundle.get();
  dictionaries.emplace(std::move(key), std::move(bundle));
  return result;
}

std::vector<std::string> reverse_lookup(DictionaryBundle *bundle,
                                        const std::string &text) {
  std::string codes;
  if (!bundle->reverse->ReverseLookup(text, &codes))
    return {};
  return split_reverse_codes(codes);
}

double lookup_weight(DictionaryBundle *bundle, const std::string &expected,
                     const std::vector<std::string> &syllables) {
  double result = -std::numeric_limits<double>::infinity();
  const auto &tables = bundle->dictionary->tables();
  for (size_t table_index = 0; table_index < tables.size(); ++table_index) {
    rime::Code code;
    for (const auto &syllable : syllables) {
      auto found = bundle->syllable_ids[table_index].find(syllable);
      if (found == bundle->syllable_ids[table_index].end()) {
        code.clear();
        break;
      }
      code.push_back(found->second);
    }
    if (code.empty())
      continue;

    const auto &table = tables[table_index];
    auto accessor = code.size() == 1 ? table->QueryWords(code[0])
                                     : table->QueryPhrases(code);
    while (!accessor.exhausted()) {
      const auto *entry = accessor.entry();
      if (entry && table->GetEntryText(*entry) == expected)
        result = std::max(result, static_cast<double>(entry->weight));
      accessor.Next();
    }
  }
  return result;
}

void add_edges(DictionaryBundle *bundle, const std::string &text,
               const std::vector<size_t> &text_offsets,
               size_t max_word_length, size_t code_limit,
               std::map<std::pair<size_t, size_t>, double> *edges) {
  const size_t character_count = text_offsets.size() - 1;
  std::vector<std::vector<std::string>> character_codes(character_count);
  for (size_t index = 0; index < character_count; ++index) {
    character_codes[index] = reverse_lookup(
        bundle, text.substr(text_offsets[index],
                            text_offsets[index + 1] - text_offsets[index]));
  }

  for (size_t beginning = 0; beginning < character_count; ++beginning) {
    const size_t maximum =
        std::min(character_count, beginning + max_word_length);
    for (size_t end = beginning + 2; end <= maximum; ++end) {
      const std::string expected =
          text.substr(text_offsets[beginning],
                      text_offsets[end] - text_offsets[beginning]);
      std::set<std::vector<std::string>> sequences;

      // Shape-code dictionaries may encode a complete phrase as one spelling.
      for (const auto &code : reverse_lookup(bundle, expected)) {
        if (code_limit > 0 && sequences.size() >= code_limit)
          break;
        sequences.insert({code});
      }

      std::vector<std::string> sequence;
      std::function<void(size_t)> combine = [&](size_t index) {
        if (code_limit > 0 && sequences.size() >= code_limit)
          return;
        if (index == end) {
          sequences.insert(sequence);
          return;
        }
        for (const auto &code : character_codes[index]) {
          sequence.push_back(code);
          combine(index + 1);
          sequence.pop_back();
          if (code_limit > 0 && sequences.size() >= code_limit)
            return;
        }
      };
      combine(beginning);

      double weight = -std::numeric_limits<double>::infinity();
      for (const auto &codes : sequences)
        weight = std::max(weight, lookup_weight(bundle, expected, codes));
      if (std::isfinite(weight))
        (*edges)[{beginning, end}] = weight;
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
        std::max<intmax_t>(1, env->extract_integer(env, args[3]));
    const size_t code_limit =
        std::max<intmax_t>(0, env->extract_integer(env, args[4]));
    const double single_weight = env->extract_float(env, args[5]);
    const auto text_offsets = utf8_boundaries(text);
    const size_t character_count = text_offsets.size() - 1;

    DictionaryBundle *dictionary = get_dictionary(schema_id, name_space);
    if (!dictionary)
      return signal_error(env, "Could not load the Rime dictionary");

    std::map<std::pair<size_t, size_t>, double> edges;
    add_edges(dictionary, text, text_offsets, max_word_length, code_limit,
              &edges);
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
  define(env, "liberime-regexp--native-query", 2, 3, query,
         "Query INPUT in SESSION without predictive completions.\n\n"
         "The query uses librime set_input and excludes genuine candidates "
         "whose Rime type is completion.\n"
         "LIMIT bounds highlighted candidate states; zero means unlimited.\n"
         "(fn SESSION INPUT &optional LIMIT)");
  define(env, "liberime-regexp--native-segment-han", 6, 6, segment_han,
         "Return reverse-dictionary word bounds for Han TEXT.\n\n"
         "(fn SCHEMA-ID NAMESPACE TEXT MAX-WORD-LENGTH CODE-LIMIT "
         "SINGLE-WEIGHT)");
  define(env, "liberime-regexp--native-clear-cache", 0, 0, clear_cache,
         "Release cached native Dictionary objects.\n\n(fn)");
  emacs_value feature = env->intern(env, "liberime-regexp-core");
  env->funcall(env, env->intern(env, "provide"), 1, &feature);
  return 0;
}
