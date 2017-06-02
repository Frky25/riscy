
// Copyright (c) 2016, 2017 Massachusetts Institute of Technology

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


import FIFO::*;
import Port::*;
import RWBRam::*;
import RVTypes::*;

typedef struct {
    Bit#(IndexW) index;
} CacheCoreReq#(numeric type IndexW);

typedef struct {
    Bool dirty;
    Maybe#(Bit#(TagW)) tag;
    Bit#(TMul#(LineBytes,8)) line;
} CacheCoreResp#(numeric type TagW, numeric type LineBytes);

typedef struct {
    Bit#(IndexW) index;
    Bit#(TMul#(FillBytes,8)) line;
    Maybe#(Bit#(TagW)) tag;
} CacheCoreFillReq#(numeric type IndexW, numeric type FillBytes, numeric type TagW);


typdef struct {
    Bool dirty
    Bit#(TMul#(LineBytes,8)) cacheLine;
    Maybe#(Bit#(TagW)) tag;
} CacheEntry#(numeric type LineBytes, numeric type TagW);


typedef TSub#(TSub#(DataSz, LogLines), LogLineBytes) TagSz#(numeric type LogLines,
                                                            numeric type LogLineBytes,
                                                            numeric type DataSz);
typedef TMul#(TExp#(LogBytes),8) BitSz#(numeric type LogBytes)

interface CacheCore#(LogLines, LogLineBytes, DataSz);
    interface InputPort#(CacheCoreReq#(LogLines)) cache_request;
    method CacheCoreResp#(TagSz#(LogLines,LogLineBytes,DataSz),TExp#(LogLineBytes)) resp;
    method Action deq;
    method Action update(Bit#(BitSz#(LogLineBytes) line);
    method Action fill(CacheCoreFillReq#(LogLines,
                                         TExp#(LogLineBytes),
                                         TagSz#(LogLines, LogLineSz, DataSz))
                                         fill_request);
endinterface

module mkDummyCacheCore(CacheCore#(LogLines, LogLineBytes, AddrSz))
    provisos(Add#(LogFillBytes, a__, LogLineBytes),
    NumAlias#(tagSz, TagSz#(LogLines, LogLineSize, DataSz)),
    NumAlias#(lineBytes, TExp#(LogLineBytes)),
    Alias#(cacheCoreReq,CacheCoreReq#(LogLines,LogLineBytes)),
    Alias#(cacheCoreResp,CacheCoreResp#(TagSz#(LogLines,LogLineBytes)))
    Alias#(cacheCoreFillReq,CacheCoreFillReq#(LogLines,
                                              LogLineBytes,
                                              tagSz)),
    Alias#(cacheEntry,CacheEntry#(LogLineBytes,tagSz)));


    interface  InputPort#(cacheCoreReq) cache_request;
        method Action enq(cacheCoreReq req);
            noAction;
        endmethod
        method Bool canEnq = true;
    endinterface
    method cacheCoreResp resp = cacheCoreResp{tag: Invalid, data: ?}
    method Action deq();
        noAction;
    endmethod
    method Action update(Bit#(XLEN) data);
        noAction;
    endmethod
    method Action fill(cacheCoreFillReq fill_request);
        noAction;
    endmethod
endmodule

module mkCacheCore(CacheCore#(LogLines, LogLineBytes))
    NumAlias#(tagSz, TagSz#(LogLines, LogLineSize)),
    NumAlias#(lineBytes, TExp#(LogLineBytes)),
    NumAlias#(lineBits, TMul#(lineBytes,8)),
    Alias#(cacheCoreReq,CacheCoreReq#(LogLines,LogLineBytes)),
    Alias#(cacheCoreResp,CacheCoreResp#(TagSz#(LogLines,LogLineBytes))),
    Alias#(cacheCoreFillReq,CacheCoreFillReq#(LogLines,
                                              LogLineBytes,
                                              tagSz)),
    Alias#(cacheEntry,CacheEntry#(LogLineBytes,tagSz))); 

    FIFO#(2,cacheCoreReq) cacheReq <- mkBypassFIFO;
    FIFO#(2,cacheCoreResp) cacheResp <- mkBypassFIFO;
    FIFO#(2,cacheCoreFillReq) fillReq <- mkFIFO;

    RWBram#(Bits#(LogLines),cacheEntry) bram <- mkRWBram;

    interface InputPort#(cacheCoreReq) cache_request = toInputPort(cacheReq);
    
    FIFO#(2, cacheCoreReq) memReq <- mkFIFO;
    FIFO#(2, cacheCoreReq) curReq <- mkFIFO;
    FIFO#(2, cacheCoreResp) curEntry <- mkFIFO;

    rule handleReq;
        let req = cacheRequest.first;
        bram.rdReq(req.index);
        memReq.enq(req);
        cacheRequest.deq;
    endrule

    rule handleBRAMResp;
        let mreq = memReq.first;
        let resp = dram.rdResp;
        curReq.enq(mreq);
        curEntry.enq(resp);
        let dirty = resp.dirty
        let tag = resp.tag;
        let cacheLine = resp.cacheLine;
        cacheResp.enq(CacheCoreResp{dirty: dirty, tag: tag, data: cacheLine});
        mreq.deq;
    endrule

    rule handleFillReq;
        let freq = fillReq.first;
        cacheEntry entry = cacheEntry{dirty: False, tag: freq.tag, data: freq.data});
        bram.wrReq(freq.index, entry);
    endrule
    
    method CacheCoreResp resp = cacheResp.first;

    method Action deq();
        curReq.deq;
        curEntry.deq;
        cacheResp.deq;
    endmethod

    method Action update(Bit#(lineBits) line) if (!fillReq.notEmpty);
        let creq = curReq.first;
        let entry = curEntry.first;
        entry.cacheLine = line;
        entry.dirty = True;
        bram.wrReq(req.index, entry);
        curReq.deq;
        curEntry.deq;
        cacheResp.deq;
    endmethod

    method Action fill(CacheCoreFillReq fill_request);
        fillReq.enq(fill_request);
    endmethod
endmodule
