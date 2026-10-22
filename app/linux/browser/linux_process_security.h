#pragma once
#include <filesystem>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

// Read only kernel metadata for this helper's own descendant tree. Do not invoke
// forbidden introspection syscalls from a sandboxed renderer or inspect profiles.
inline bool RendererHasSeccomp(int browser_pid, int renderer_namespace_pid,
                              const std::filesystem::path& proc = "/proc") {
  if (browser_pid <= 0 || renderer_namespace_pid <= 0) return false;
  std::vector<int> queue{browser_pid};
  std::set<int> visited;
  bool found = false;
  while (!queue.empty()) {
    const int pid = queue.back(); queue.pop_back();
    if (!visited.insert(pid).second) continue;
    if (visited.size() > 512) return false;
    if (pid != browser_pid) {
      std::ifstream status(proc / std::to_string(pid) / "status");
      std::string line;
      int namespace_pid = -1, seccomp = -1;
      while (std::getline(status, line)) {
        std::istringstream fields(line); std::string key; fields >> key;
        if (key == "NSpid:") { int value; while (fields >> value) namespace_pid = value; }
        else if (key == "Seccomp:") fields >> seccomp;
      }
      if (namespace_pid == renderer_namespace_pid) {
        found = true;
        if (seccomp != 2) return false;
      }
    }
    std::error_code error;
    const auto tasks = proc / std::to_string(pid) / "task";
    const auto options = std::filesystem::directory_options::skip_permission_denied;
    for (const auto& task : std::filesystem::directory_iterator(tasks, options, error)) {
      std::ifstream children(task.path() / "children"); int child;
      while (children >> child) if (child > 0) queue.push_back(child);
    }
  }
  return found;
}
