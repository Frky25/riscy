
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

import FIFO::*;
import GetPut::*;

import Abstraction::*;
import RVRFile::*;
`ifdef CONFIG_U
import RVCsrFile::*;
`else
import RVCsrFileMCU::*;
`endif
import RVTypes::*;
import VerificationPacket::*;

import RVMemory::*;
`ifdef CONFIG_M
import RVMulDiv::*;
`endif

interface WriteBackStage;
endinterface

typedef struct {
    Reg#(Maybe#(FetchState)) fs;
    Reg#(Maybe#(RegFetchState)) rs;
    Reg#(Maybe#(ExecuteState)) es;
    Reg#(Maybe#(WriteBackState)) ws;
    Get#(RVDMemResp) dmemres;
`ifdef CONFIG_M
    MulDivExec mulDiv;
`endif
`ifdef CONFIG_U
    // If user mode is supported, use the full CSR File
    RVCsrFile csrf;
`else
    // Otherwise use the M-only CSR File designed for MCUs
    RVCsrFileMCU csrf;
`endif
    ArchRFile rf;
    FIFO#(VerificationPacket) verificationPackets;
} WriteBackRegs;

module mkWriteBackStage#(WriteBackRegs wr)(WriteBackStage);
    let dmemres = wr.dmemres;
    let csrf = wr.csrf;
    let rf = wr.rf;
`ifdef CONFIG_M
    let mulDiv = wr.mulDiv;
`endif

    rule doWriteBack(wr.ws matches tagged Valid .writeBackState
                        &&& (writeBackState.dInst.execFunc != tagged System WFI || csrf.wakeFromWFI()));
        let pc = writeBackState.pc;
        let trap = writeBackState.trap;
        let dInst = writeBackState.dInst;
        let inst = dInst.inst;
        let addr = writeBackState.addr;
        let data = writeBackState.data;
        wr.ws <= tagged Invalid;
        //$display("[WriteBack] pc: 0x%0x, dInst: ", pc, fshow(dInst));

`ifdef CONFIG_M
        if (dInst.execFunc matches tagged MulDiv .* &&& trap == tagged Invalid) begin
            data = mulDiv.result_data;
            mulDiv.result_deq;
        end
`endif

        if (dInst.execFunc matches tagged Mem .memInst &&& trap == tagged Invalid) begin
            if (getsResponse(memInst.op)) begin
                data <- dmemres.get;
            end
        end

        let csrfResult <- csrf.wr(
                pc,
                // performing system instructions
                dInst.execFunc matches tagged System .sysInst ? tagged Valid sysInst : tagged Invalid,
                getInstFields(inst).csr,
                data, // either rf[rs1] or zimm, computed in basicExec
                addr,
                // handling exceptions
                trap,
                // indirect writes
                0,
                False,
                False);

        Maybe#(Addr) maybeNextPc = tagged Invalid;
        Maybe#(Data) maybeData = tagged Invalid;
        Maybe#(TrapCause) maybeTrap = tagged Invalid;
        case (csrfResult) matches
            tagged Exception .exc:
                begin
                    maybeNextPc = tagged Valid exc.trapHandlerPC;
                    maybeTrap = tagged Valid exc.exception;
                end
            tagged RedirectPC .newPc:
                maybeNextPc = tagged Valid newPc;
            tagged CsrData .data:
                maybeData = tagged Valid data;
            tagged None:
                noAction;
        endcase

        // send verification packet
        Bool isInterrupt = False;
        Bool isException = False;
        Bit#(4) trapCause = 0;
        case (maybeTrap) matches
            tagged Valid (tagged Interrupt .x):
                begin
                    isInterrupt = True;
                    trapCause = pack(x);
                end
            tagged Valid (tagged Exception .x):
                begin
                    isException = True;
                    trapCause = pack(x);
                end
        endcase
        wr.verificationPackets.enq( VerificationPacket {
                skippedPackets: 0,
                pc: signExtend(pc),
                data: signExtend(fromMaybe(data, maybeData)),
                addr: signExtend(addr),
                instruction: inst,
                dst: {pack(dInst.dst), getInstFields(inst).rd},
                exception: isException,
                interrupt: isInterrupt,
                cause: trapCause } );

        if (maybeNextPc matches tagged Valid .replayPc) begin
            // This instruction is not writing to the register file
            // it is either an instruction that requires flushing the pipeline
            // or it caused an exception
            //$display("[WriteBack] Redirecting to pc: 0x%0x", replayPc);
            wr.fs <= tagged Valid FetchState{ pc: replayPc };
            // kill other instructions
            if (wr.rs matches tagged Valid .validRegFetchState) begin
                let vrs = validRegFetchState;
                vrs.poisoned = True;
                wr.rs <= tagged Valid vrs;
            end
            if (wr.es matches tagged Valid .validExecuteState) begin
                let ves = validExecuteState;
                ves.poisoned = True;
                wr.es <= tagged Valid ves;
            end
        end else begin
            // This instruction retired
            // write to the register file
            rf.wr(toFullRegIndex(dInst.dst, getInstFields(inst).rd), fromMaybe(data, maybeData));
        end
    endrule
endmodule
