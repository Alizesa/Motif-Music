#include <fileref.h>
#include <tfilestream.h>
#include <tag.h>
#include <audioproperties.h>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#ifndef _WIN32
#include <unistd.h>
#include <fcntl.h>
#endif

#ifdef _WIN32
#define MOTIF_EXPORT extern "C" __declspec(dllexport)
#else
#define MOTIF_EXPORT extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif

namespace {
std::string quoted(const TagLib::String &value) {
  const auto bytes = value.to8Bit(true);
  std::string out = "\"";
  static constexpr char hex[] = "0123456789abcdef";
  for (unsigned char c : bytes) {
    if (c == '"' || c == '\\') { out += '\\'; out += c; }
    else if (c < 0x20) { out += "\\u00"; out += hex[c >> 4]; out += hex[c & 15]; }
    else { out += c; }
  }
  return out + "\"";
}

// FileRef does not own the stream; it must be destroyed first.
char *extract(TagLib::FileStream &stream) {
  if (!stream.isOpen() || !stream.readOnly()) return nullptr;
  TagLib::FileRef file(&stream, true, TagLib::AudioProperties::Fast);
  if (file.isNull() || !file.file()->isValid()) return nullptr;
  const auto *tag = file.tag();
  const auto *audio = file.audioProperties();
  const auto duration = audio ? audio->lengthInMilliseconds() : 0;
  const TagLib::String empty;
  const std::string json = "{\"title\":" + quoted(tag ? tag->title() : empty) +
      ",\"artist\":" + quoted(tag ? tag->artist() : empty) +
      ",\"album\":" + quoted(tag ? tag->album() : empty) +
      ",\"durationMs\":" + (duration > 0 ? std::to_string(duration) : "null") + "}";
  auto *result = static_cast<char *>(std::malloc(json.size() + 1));
  if (result) std::memcpy(result, json.c_str(), json.size() + 1);
  return result;
}
}

MOTIF_EXPORT char *motif_taglib_read_path(const char *path) {
  if (!path || !*path) return nullptr;
  try {
#ifdef _WIN32
    const TagLib::String utf8Path(path, TagLib::String::UTF8);
    const auto widePath = utf8Path.toWString();
    TagLib::FileStream stream(widePath.c_str(), true);
#else
    TagLib::FileStream stream(path, true);
#endif
    return extract(stream);
  } catch (...) { return nullptr; }
}

MOTIF_EXPORT char *motif_taglib_read_fd(int borrowedFd) {
#ifndef _WIN32
  // Java retains its ParcelFileDescriptor. Only this duplicate is consumed by
  // FileStream/fclose; never close the borrowed descriptor supplied by Dart.
  if (borrowedFd < 0 || (fcntl(borrowedFd, F_GETFL) & O_ACCMODE) != O_RDONLY) return nullptr;
  int ownedFd = dup(borrowedFd);
  if (ownedFd < 0) return nullptr;
  try {
    if (lseek(ownedFd, 0, SEEK_SET) < 0) { close(ownedFd); return nullptr; }
    TagLib::FileStream stream(ownedFd, true);
    if (!stream.isOpen()) { close(ownedFd); return nullptr; }
    ownedFd = -1; // Stream owns it until its destructor, including failures.
    return extract(stream);
  } catch (...) {
    if (ownedFd >= 0) close(ownedFd);
    return nullptr;
  }
#else
  return nullptr;
#endif
}

MOTIF_EXPORT void motif_taglib_free(char *value) { std::free(value); }

MOTIF_EXPORT void motif_taglib_close_fd(int fd) {
#ifndef _WIN32
  if (fd >= 0) close(fd);
#endif
}
