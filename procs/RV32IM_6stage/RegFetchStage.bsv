
// Copyright (c) 2017 Massachusetts Institute of Technology

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

`include "ProcConfig.bsv"

import CoreStates::*;

import GetPut::*;

import RVRFile::*;
`ifdef CONFIG_U
import RVCsrFile::*;
`else
import RVCsrFileMCU::*;
`endif
import RVTypes::*;

import RVDecode::*;

interface RegFetchStage;
endinterface

typedef struct {
    Reg#(Maybe#(RegFetchState)) rs;
    Reg#(Maybe#(ExecuteState)) es;
    Get#(Instruction) ifetchres;
`ifdef CONFIG_U
    // If user mode is supported, use the full CSR File
    RVCsrFile csrf;
`else
    // Otherwise use the M-only CSR File designed for MCUs
    RVCsrFileMCU csrf;
`endif
    ArchRFile rf;
}RegFetchRegs;

module mkRegFetchStage#(RegFetchRegs rr)(RegFetchStage);

    let ifetchres = rr.ifetchres;
    let csrf = rr.csrf;
    let rf = rr.rf;

    rule doRegFetch(rr.rs matches tagged Valid .regFetchState
                    &&& rr.es == tagged Invalid);
        // get and clear the execute state
        let poisoned = regFetchState.poisoned;
        let pc = regFetchState.pc;
        rr.rs <= tagged Invalid;

        // get the instruction
        let inst <- ifetchres.get;

        if (!poisoned) begin
            // check for interrupts
            Maybe#(TrapCause) trap = tagged Invalid;
            if (csrf.readyInterrupt matches tagged Valid .validInterrupt) begin
                trap = tagged Valid (tagged Interrupt validInterrupt);
            end

            // decode the instruction
            let maybeDInst = decodeInst(inst);
            if (maybeDInst == tagged Invalid && trap == tagged Invalid) begin
                trap = tagged Valid (tagged Exception IllegalInst);
            end
            let dInst = fromMaybe(?, maybeDInst);

            //$display("[RegFetch] pc: 0x%0x, inst: 0x%0x, dInst: ", pc, inst, fshow(dInst));

            // read registers
            let rVal1 = rf.rd1(toFullRegIndex(dInst.rs1, getInstFields(inst).rs1));
            let rVal2 = rf.rd2(toFullRegIndex(dInst.rs2, getInstFields(inst).rs2));
            rr.es <= tagged Valid ExecuteState{
                poisoned: False,
                pc: pc,
                trap: trap,
                dInst: dInst,
                rVal1: rVal1,
                rVal2: rVal2
                };
        end
    endrule
endmodule
