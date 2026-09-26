#include "framegen/FGWorkGate.h"
#include "framegen/xefg/XeFGRecovery.h"
#include "framegen/IFGFeature_Reset.h"
#include <cassert>
#include <iostream>
#include <mutex>
#include <unordered_map>
using UINT64=uint64_t;constexpr unsigned BUFFER_COUNT=4;
enum class FG_ResourceType{Depth,Velocity,UIColor,HudlessColor};
struct Config{struct Option{unsigned value_or_default()const{return 3;}}FGAllowedFrameAhead;static Config* Instance(){static Config c;return &c;}};
struct State{unsigned fgLastFrame=0;static State& Instance(){static State s;return s;}};
#define LOG_WARN(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
namespace XeFGDiagnostics{inline uint64_t now=0;inline uint64_t WorkNowMs(){return now;}}
struct IFGFeature{
    UINT64 _frameCount=10,_lastDispatchedFrame=0,_lastFGFrame=0;
    std::unordered_map<int,bool> _resourceReady[BUFFER_COUNT];
    bool _waitingExecute[BUFFER_COUNT]{},_noUi[BUFFER_COUNT]{},_noDistortionField[BUFFER_COUNT]{},_noHudless[BUFFER_COUNT]{};
    FGHistoryResetLatch _historyReset;
    virtual ~IFGFeature()=default;
    virtual UINT64 StartNewFrame();virtual void SetFrameCount(UINT64);
    int GetIndex(){return static_cast<int>(_frameCount%BUFFER_COUNT);}
    int GetDispatchIndex(UINT64&);bool HasResource(FG_ResourceType type,int slot){return _resourceReady[slot].contains(static_cast<int>(type));}
    void NewFrame(){} // External command/helper boundary; no SDK or recovery decisions.
};
struct XeFG_Dx12:IFGFeature{
    FGWorkGate _workGate;XeFGRecovery _recovery;
    auto AcquireWork(){return _workGate.TryEnter();}
    UINT64 StartNewFrame() override;void SetFrameCount(UINT64) override;
};
using IFGFeature_Dx12=XeFG_Dx12;
struct Sl1_Inputs_Dx12{
    std::mutex _frameBoundaryMutex;bool _isFrameFinished=false;
    uint32_t _lastPresentFrameId=10;int _currentIndex=0;uint32_t _frameIdIndex[BUFFER_COUNT]{};
    void CheckForFrame(IFGFeature_Dx12*,uint32_t);
};
// ACTUAL_FUNCTIONS
int main(){
    XeFG_Dx12 fg;Sl1_Inputs_Dx12 input;
    assert(fg._recovery.Fault(10,0));auto ticket=fg._recovery.DisableTicket(0);fg._recovery.Disabled(ticket,true,0);
    input.CheckForFrame(&fg,11);input.CheckForFrame(&fg,11);
    assert(fg._frameCount==11);
    assert(fg._recovery.State()==XeFGRecovery::Phase::Backoff && "duplicate SL1 preincrement must not restart recovery backoff");
    XeFGDiagnostics::now=64;input.CheckForFrame(&fg,12);
    auto trial=fg._recovery.BeginTrial(fg._frameCount,64);assert(trial!=0);
    fg._recovery.Enabled(trial,true,64);
    input.CheckForFrame(&fg,12);
    assert(fg._recovery.State()==XeFGRecovery::Phase::Trial && "same-frame producer bookkeeping must not disable a trial");
    fg.SetFrameCount(1);assert(fg._frameCount==1);
    assert(fg._recovery.Recovering() && fg._recovery.PresentToken()==0);
    {
        XeFG_Dx12 ahead;assert(ahead._recovery.Fault(10,0));auto disable=ahead._recovery.DisableTicket(0);ahead._recovery.Disabled(disable,true,0);
        auto enable=ahead._recovery.BeginTrial(11,64);assert(enable);ahead._recovery.Enabled(enable,true,64);
        ahead._recovery.ConstantsReady(11);ahead._recovery.Accepted(11,XeFGRecovery::Depth);ahead._recovery.Accepted(11,XeFGRecovery::Velocity);
        ahead._recovery.ConstantsReady(12);ahead._recovery.Accepted(12,XeFGRecovery::Depth);
        ahead._recovery.ConstantsReady(13);ahead._recovery.Accepted(13,XeFGRecovery::Velocity);
        ahead._frameCount=13;ahead._lastDispatchedFrame=10;UINT64 chosen=0;
        assert(ahead.GetDispatchIndex(chosen)==3 && chosen==11 && ahead._recovery.Ready(chosen,true));
        assert(ahead.GetDispatchIndex(chosen)==0 && chosen==12 && !ahead._recovery.Ready(chosen,true));
        ahead._recovery.Accepted(15,XeFGRecovery::Depth);assert(!ahead._recovery.Ready(11,true));
    }
    std::cout<<"PASS: actual SL1 frame boundary and XeFG rebase preserve bounded recovery progress\n";
}
