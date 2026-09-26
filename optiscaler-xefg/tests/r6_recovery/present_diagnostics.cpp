#include "misc/XeFGPresentDiagnostics.h"
#include <cassert>
#include <iostream>
#include <thread>
#include <vector>
#include <latch>
using namespace XeFGDiagnostics;
int main() {
    auto initial=ReadPresentSnapshot();
    for(unsigned frames=0;frames<8;++frames) {
        PresentObservation observation;
        assert(observation.Record(0,true,0,frames,0,true));
        assert(observation.Record(0,true,0,99,-1,false)); // exactly one observation
    }
    auto counts=ReadPresentSnapshot();
    assert(counts.calls-initial.calls==8 && counts.validSamples-initial.validSamples==8);
    assert(counts.queuedFrames-initial.queuedFrames==28);
    for(unsigned bucket=0;bucket<8;++bucket) assert(counts.queuedHistogram[bucket]-initial.queuedHistogram[bucket]==1);
    auto before=counts;
    { PresentObservation o;assert(!o.Record(0,true,5,777,-9,true)); }
    { PresentObservation o;assert(!o.Record(0,true,-1,777,0,true)); }
    { PresentObservation o;assert(!o.Record(-5,true,0,777,0,true)); }
    { PresentObservation o;assert(!o.Record(1,true,0,777,0,true)); }
    { PresentObservation o;assert(!o.Record(0,false,0,777,0,true)); }
    { PresentObservation o(true);assert(!o.Record(0,true,0,777,0,true)); }
    counts=ReadPresentSnapshot();
    assert(counts.validSamples==before.validSamples && counts.queuedFrames==before.queuedFrames);
    assert(counts.queryWarnings==before.queryWarnings+1 && counts.queryErrors==before.queryErrors+1);
    assert(counts.nativeFailures==before.nativeFailures+1 && counts.nativeNonzeroSuccess==before.nativeNonzeroSuccess+1);
    assert(counts.apiUnavailable==before.apiUnavailable+1 && counts.testCalls==before.testCalls+1);
    before=counts;
    { PresentObservation o;assert(o.Record(0,true,0,6,1,true)); }
    { PresentObservation o;assert(o.Record(0,true,0,1,-9,true)); }
    { PresentObservation o;assert(o.Record(0,true,0,1,0,false)); }
    counts=ReadPresentSnapshot();
    assert(counts.frameWarnings==before.frameWarnings+1 && counts.frameErrors==before.frameErrors+1);
    assert(counts.disabledSamples==before.disabledSamples+1 && !counts.lastEnabled && counts.lastQueuedFrames==1);
    assert(counts.lastNonzeroFrameResult==-9 && counts.lastNonzeroQuery==-1);
    before=counts;
    {
        PresentObservation outer;
        { PresentObservation nestedTest(true);assert(!nestedTest.Record(0,true,0,6,0,true));assert(nestedTest.IsAmbiguous()); }
        assert(!outer.Record(0,true,0,6,0,true) && outer.IsAmbiguous());
    }
    counts=ReadPresentSnapshot();assert(counts.ambiguous==before.ambiguous+2 && counts.validSamples==before.validSamples);
    before=counts;
    std::latch entered{8}, mayRecord{1};std::vector<std::thread> threads;
    for(unsigned i=0;i<8;++i) threads.emplace_back([&]{PresentObservation o;entered.count_down();mayRecord.wait();assert(!o.Record(0,true,0,6,0,true));});
    entered.wait();mayRecord.count_down();for(auto& t:threads)t.join();
    counts=ReadPresentSnapshot();assert(counts.ambiguous==before.ambiguous+8 && counts.validSamples==before.validSamples);
    before=counts;
    { InputObservation input(InputKind::Depth);input.Accept();input.Accept(); }
    { InputObservation input(InputKind::Velocity);input.Reject(InputReason::RecoveryBackoff); }
    { InputObservation input(InputKind::Hudless);input.Accept();input.Reject(InputReason::ProviderRejected); }
    { InputObservation input(InputKind::UI); }
    counts=ReadPresentSnapshot();
    assert(counts.inputAccepted[0]==before.inputAccepted[0]+1);
    assert(counts.inputRejected[1]==before.inputRejected[1]+1 && counts.inputRejected[2]==before.inputRejected[2]+1);
    assert(counts.inputRejected[3]==before.inputRejected[3]+1);
    assert(counts.inputReasons[static_cast<unsigned>(InputReason::Accepted)]==before.inputReasons[static_cast<unsigned>(InputReason::Accepted)]+1);
    before=counts;RecordTagResult(InputKind::Depth,0);RecordTagResult(InputKind::Depth,2);RecordTagResult(InputKind::Depth,-2);
    counts=ReadPresentSnapshot();assert(counts.tagsAccepted[0]==before.tagsAccepted[0]+2 && counts.tagsRejected[0]==before.tagsRejected[0]+1);
    assert(counts.tagWarnings==before.tagWarnings+1 && counts.lastTagResult==-2);
    RecordActivation(true,0,ActivationReason::Normal);
    RecordActivation(false,-9,ActivationReason::RecoveryDisable);
    counts=ReadPresentSnapshot();assert(counts.activationKnown && counts.lastAcceptedEnabled && !counts.lastRequestedEnabled && counts.lastActivationResult==-9);
    RecordActivation(false,1,ActivationReason::RecoveryDisable);
    counts=ReadPresentSnapshot();assert(counts.lastAcceptedEnabled && counts.activationWarnings>0);
    RecordActivation(false,0,ActivationReason::RecoveryDisable);
    assert(!ReadPresentSnapshot().lastAcceptedEnabled);
    RecordProviderVersion(1,3,1);RecordHeapRequirements(100,200,300);
    counts=ReadPresentSnapshot();assert(counts.versionKnown && counts.versionMinor==3 && counts.heapRequirementsKnown && counts.requiredTextureBytes==200);
    RecordInterpolationCapacity(5,2,true);RecordInterpolationActive(2);
    counts=ReadPresentSnapshot();assert(counts.interpolationKnown&&counts.maxInitializedInterpolations==5);
    assert(counts.configuredInterpolations==2&&counts.configuredExplicit&&counts.activeInterpolations==2);
    std::cout<<"PASS: production present truth, warning/error separation, overlap ambiguity and input/activation accounting\n";
}
