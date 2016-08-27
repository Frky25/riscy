
// Copyright (c) 2016 Massachusetts Institute of Technology

// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#include <errno.h>
#include <stdio.h>
#include <cstring>
#include <cassert>
#include <fcntl.h>
#include <string.h>
#include <iostream>
#include <sys/stat.h>
#include <unistd.h>
#include <semaphore.h>
#include <vector>
#include <string>
#include <sstream>
#include <list>
#include <signal.h>
#include "DmaBuffer.h"

#include "Platform.hpp"
#include "ProcControl.hpp"
#include "Verification.hpp"
#include "PerfMonitor.hpp"
#include "ExternalMMIO.hpp"
#include "HTIF.hpp"
#include "DeviceTree.hpp"

#include "NullTandemVerifier.hpp"
#include "SpikeTandemVerifier.hpp"
#include "PrintTrace.hpp"

#include "GeneratedTypes.h"

#ifdef NDEBUG
#error fesvr will not work with NDEBUG defined
#endif

#define CONNECTAL_MEMORY

#define BLURT fprintf (stderr, "CPPDEBUG: %s(%s):%d\n",\
                      __func__, __FILE__, __LINE__)

// main stuff
static Platform *platform = NULL;
static ProcControl *procControl = NULL;
static Verification *verification = NULL;
static PerfMonitor *perfMonitor = NULL;
static ExternalMMIO *externalMMIO = NULL;
static HTIF *htif = NULL;

// The amount of RAM attached to the processor. 64 MB by default
size_t ramSz = 64 * 1024 * 1024;
// The size of the ROM attached to the uncached region. 64 KB by default
size_t romSz = 64 * 1024;

// What do we do with this?
static void handle_signal(int sig) {
    fprintf(stderr, "\n>> Ctrl-C: Exiting...\n");
    if (verification != NULL) {
        verification->printStatus();
    }
    exit(1);
}

void printHelp(const char *prog)
{
    fprintf(stderr, "Usage: %s [--just-run] HTIF_ARGS\n", prog);
}

int main(int argc, char * const *argv) {
    // command line argument parsing
    // strip prog_name off of the command line arguments
    const char *prog_name = argv[0];
    argc--;
    argv++;
    // if the first argument is "-h" or "--help", print help
    if (argc > 0 && ((strcmp(argv[0], "-h") == 0) || (strcmp(argv[0], "--help") == 0))) {
        printHelp(prog_name);
        exit(0);
    }
    // if the next argument is "--just-run" remove it and set just_run to true
    bool just_run = false;
    bool just_trace = false;
    if (argc > 0 && strcmp(argv[0], "--just-run") == 0) {
        just_run = true;
        argc--;
        argv++;
    }
    if (argc > 0 && strcmp(argv[0], "--just-trace") == 0) {
        just_trace = true;
        argc--;
        argv++;
    }

    signal(SIGINT, &handle_signal);

    long actualFrequency = 0;
    long requestedFrequency = 1e9 / MainClockPeriod;

#ifdef SIMULATION // safe to always do this, but it's only useful for simulation
    char socket_name[128];
    snprintf(socket_name, sizeof(socket_name), "SOCK.%d", getpid());
    setenv("BLUESIM_SOCKET_NAME", socket_name, 0);
    setenv("SOFTWARE_SOCKET_NAME", socket_name, 0);
#endif

    // format htif args
    std::vector<std::string> htif_args;
    fprintf(stderr, "htif_args: ");
    for (int i = 0 ; i < argc ; i++ ) {
        // adding argument
        htif_args.push_back(argv[i]);
        // printing arguments
        fprintf(stderr, "%s", argv[i]);
        if (i == argc-1) {
            fprintf(stderr, "\n");
        } else {
            fprintf(stderr, ", ");
        }
    }

    // objects for controlling the interaction with the processor
    procControl = new ProcControl(IfcNames_ProcControlIndicationH2S, IfcNames_ProcControlRequestS2H);
    if (just_run) {
        procControl->configureVerificationPackets(0xFFFFFFFFFFFFFFFFLL, false);
        verification = new Verification(IfcNames_VerificationIndicationH2S, new NullTandemVerifier());
    } else if (just_trace) {
        verification = new Verification(IfcNames_VerificationIndicationH2S, new PrintTrace());
    } else {
        // ERROR
        fprintf(stderr, "WARNING: Spike-based tandem verification is not fully tested for priv spec v1.9 yet\n");
        verification = new Verification(IfcNames_VerificationIndicationH2S, new SpikeTandemVerifier(htif_args, ramSz));
    }
    perfMonitor = new PerfMonitor(IfcNames_PerfMonitorIndicationH2S, IfcNames_PerfMonitorRequestS2H);
    externalMMIO = new ExternalMMIO(IfcNames_ExternalMMIORequestH2S, IfcNames_ExternalMMIOResponseS2H);

    int status = setClockFrequency(0, requestedFrequency, &actualFrequency);
    printf("Requested main clock frequency %5.2f, actual clock frequency %5.2f MHz status=%d errno=%d\n",
        (double)requestedFrequency * 1.0e-6,
        (double)actualFrequency * 1.0e-6,
        status, (status != 0) ? errno : 0);

    // construct platform
    platform = new Platform(IfcNames_PlatformIndicationH2S,
                            IfcNames_PlatformRequestS2H,
                            0x80000000, ramSz,  // ram base and size
                            0,          romSz); // rom base and size
    platform->init();

    // Connect an HTIF module up to the procControl interfaces
    htif = new HTIF(htif_args, procControl, platform);

    // This function loads the specified program, and runs the test
    int result = htif->run();
    perfMonitor->setEnable(0);

    if (result == 0) {
        fprintf(stderr, "[32mPASSED[39m\n");
    } else {
        fprintf(stderr, "[31mFAILED %d[39m\n", (int) result);
    }

#ifdef SIMULATION
    unlink(socket_name);
#endif

    fprintf(stderr, "---- Verification results: ------------------------------------------\n");
    verification->printStatus();
    fprintf(stderr, "\n");
    fprintf(stderr, "---- PerfMonitor results: -------------------------------------------\n");
    perfMonitor->printPerformance("verilator/Proc.perfmon.txt");
    fprintf(stderr, "\n");

    fflush(stdout);
    fflush(stderr);

    return result;
}
