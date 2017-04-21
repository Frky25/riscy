
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

import RVTypes::*;
import CoreStates::*;
import GetPut::*;
import Btb::*;
import Bht::*;

`ifdef CONFIG_U
import RVCsrFile::*;
`else
import RVCsrFileMCU::*;
`endif
import RVDecode::*;

interface FetchStage;
endinterface

typedef struct {
    Reg#(Maybe#(FetchState)) fs;
    Reg#(Maybe#(DecodeState)) ds;
    Put#(Addr) ifetchreq;
    NextAddrPred btb;
} FetchRegs;

typedef struct {
    Reg#(Maybe#(FetchState)) fs;
    Reg#(Maybe#(DecodeState)) ds;
    Reg#(Maybe#(RegFetchState)) rs;
    Get#(Instruction) ifetchres;
`ifdef CONFIG_U
    // If user mode is supported, use the full CSR File
    RVCsrFile csrf;
`else
    // Otherwise use the M-only CSR File designed for MCUs
    RVCsrFileMCU csrf;
`endif
    DirPred bht;
} DecodeRegs;


module mkFetchStage#(FetchRegs fr, DecodeRegs dr)(FetchStage);
    let ifetchreq = fr.ifetchreq;
    let btb = fr.btb;

    rule doFetch(fr.fs matches tagged Valid .fetchState
                    &&& fr.ds == tagged Invalid);
        // get and clear the fetch state
        let pc = fetchState.pc;
        let ppc = btb.predPc(pc);
        //fr.fs <= tagged Invalid;
        //$display("[Fetch] pc: 0x%0x", pc);
        // request instruction
        ifetchreq.put(pc);

        // update pc
        fr.fs <= tagged Valid FetchState{pc: ppc};

        // pass to execute state
        fr.ds <= tagged Valid DecodeState{ poisoned: False, pc: pc, ppc: ppc};
    endrule

    let ifetchres = dr.ifetchres;
    let csrf = dr.csrf;
    let bht = dr.bht;

    rule doDecode(dr.ds matches tagged Valid .decodeState
                    &&& dr.rs == tagged Invalid);

        // get and clear the execute state
        let poisoned = decodeState.poisoned;
        let pc = decodeState.pc;
        let ppc = decodeState.ppc;

        Instruction inst <- ifetchres.get;
        dr.ds <= tagged Invalid;

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
            
            if (dInst.execFunc matches tagged Br .br) begin
                if(br != Jal && br != Jalr) begin
                    let pred = bht.dirPred(pc);
                    Addr bppc = 0;
                    if(pred) begin
                        let imm = fromMaybe(?,getImmediate(dInst.imm, dInst.inst));
                        bppc = pc + signExtend(imm);
                    end else begin
                        bppc = pc + 4;
                    end
                    
                    if(bppc != ppc) begin
                        dr.fs <= tagged Valid FetchState{ pc: bppc };
                        ppc = bppc;
                    end
                end
                if(br == Jal) begin
                    let imm = fromMaybe(?,getImmediate(dInst.imm, dInst.inst));
                    Addr jppc = pc + signExtend(imm);
                    if(jppc != ppc) begin
                        dr.fs <= tagged Valid FetchState{ pc: jppc };
                        ppc = jppc;
                    end
                end
            end

            dr.rs <= tagged Valid RegFetchState{
                        poisoned: poisoned,
                        pc: pc,
                        ppc: ppc,
                        trap: trap,
                        inst: inst,
                        dInst: dInst};
        end
    endrule
endmodule
