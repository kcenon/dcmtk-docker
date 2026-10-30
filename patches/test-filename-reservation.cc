// Linux regression for #115: concurrent allocators must reserve distinct paths.
#include "dcmtk/config/osconfig.h"
#include "dcmtk/dcmqrdb/dcmqrdbi.h"
#include "dcmtk/dcmdata/dcuid.h"
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>

int main()
{
    char directory[] = "/tmp/dcmtk-reservation-XXXXXX";
    if (!mkdtemp(directory)) return 1;
    // Initialize the index before starting concurrent association handlers.
    {
        OFCondition status;
        DcmQueryRetrieveIndexDatabaseHandle db(directory, 200, 1024 * 1024, status);
        if (status.bad()) return 1;
    }
    int start[2], results[2];
    if (pipe(start) || pipe(results)) return 1;
    const int workers = 16, allocations = 8;
    std::vector<pid_t> children;
    for (int w = 0; w < workers; ++w)
    {
        pid_t pid = fork();
        if (pid < 0) return 1;
        if (!pid)
        {
            close(start[1]); close(results[0]);
            char token;
            if (read(start[0], &token, 1) != 1) _exit(1);
            OFCondition status;
            DcmQueryRetrieveIndexDatabaseHandle db(directory, 200, 1024 * 1024, status);
            if (status.bad()) _exit(1);
            for (int i = 0; i < allocations; ++i)
            {
                char name[512], uid[80], record[560];
                std::snprintf(uid, sizeof(uid), "1.2.826.0.1.3680043.8.499.90.%d.%d", w + 1, i + 1);
                if (db.makeNewStoreFileName(UID_CTImageStorage, uid, name, sizeof(name)).bad()) _exit(1);
                struct stat st;
                const int reserved = stat(name, &st) == 0 && S_ISREG(st.st_mode);
                int n = std::snprintf(record, sizeof(record), "%d\t%s\n", reserved, name);
                if (write(results[1], record, n) != n) _exit(1);
            }
            _exit(0);
        }
        children.push_back(pid);
    }
    close(start[0]); close(results[1]);
    for (int w = 0; w < workers; ++w)
        if (write(start[1], "x", 1) != 1) return 1;
    close(start[1]);
    FILE *stream = fdopen(results[0], "r");
    if (!stream) return 1;
    std::set<std::string> names;
    int reserved = 0, count = 0, failed = 0;
    char line[560];
    while (std::fgets(line, sizeof(line), stream))
    {
        ++count;
        reserved += line[0] == '1';
        std::string name(line + 2);
        name.erase(name.find_last_not_of("\n") + 1);
        names.insert(name);
    }
    std::fclose(stream);
    for (pid_t pid : children)
    {
        int status;
        if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status) || WEXITSTATUS(status)) ++failed;
    }
    std::printf("allocations=%d unique=%zu reserved=%d child_failures=%d expected=%d\n",
                count, names.size(), reserved, failed, workers * allocations);
    for (const auto &name : names) unlink(name.c_str());
    unlink((std::string(directory) + "/index.dat").c_str());
    rmdir(directory);
    return count == workers * allocations && names.size() == static_cast<size_t>(count)
        && reserved == count && failed == 0 ? 0 : 1;
}
