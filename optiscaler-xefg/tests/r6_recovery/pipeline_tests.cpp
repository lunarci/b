static void ResetGlobals(){*Config::Instance()=Config{};State::Instance()=State{};XeFGProxy::Reset();XeFGDiagnostics::testNow=0;}
static void Frame(XeFG_Dx12& s,uint64_t frame,int slot=0){s._frameCount=frame;s.currentSlot=slot;s._frameResources[slot].clear();s._resourceReady[slot].clear();s._noHudless[slot]=s._noUi[slot]=s._noDistortionField[slot]=true;}
static Dx12Resource Input(ID3D12Resource& resource,FG_ResourceType type,int slot=-1){Dx12Resource x;x.resource=&resource;x.type=type;x.frameIndex=slot;return x;}
static bool Fresh(XeFG_Dx12& s,uint64_t frame,bool hudless=false){
    static ID3D12Resource depth,mv,color;Frame(s,frame,static_cast<int>(frame%BUFFER_COUNT));s.MarkFrameConstantsReady(frame);
    auto d=Input(depth,FG_ResourceType::Depth),v=Input(mv,FG_ResourceType::Velocity),h=Input(color,FG_ResourceType::HudlessColor);
    if(!s.SetResource(&d)||!s.SetResource(&v))return false;
    if(hudless&&!s.SetResource(&h))return false;
    s.PreparePresent();return s.Dispatch();
}
int main(){
    {
        ResetGlobals();XeFG_Dx12 s;ID3D12Resource color;auto in=Input(color,FG_ResourceType::HudlessColor);
        in.validity=FG_ResourceValidity::UntilPresentFromDispatch;assert(s.SetResource(&in));color.format=87;
        for(unsigned i=0;i<100;++i){Frame(s,100+i);assert(s.SetResource(&in));assert(!State::Instance().fgChanged);}
        assert(XeFGProxy::tagCalls==101 && s.historyRequests==1 && s._hudlessAcceptedFormat[0]==87);
        for(unsigned i=0;i<40;++i){const int slot=i%2;Frame(s,300+i,slot);color.format=slot?28:87;in.frameIndex=slot;assert(s.SetResource(&in));}
        assert(s.historyRequests==1 && s._hudlessAcceptedFormat[1]==28);
        XeFG_Dx12 other;in.frameIndex=0;color.format=28;assert(other.SetResource(&in));assert(other.historyRequests==0);
    }
    {
        ResetGlobals();XeFG_Dx12 s;ID3D12Resource resource;auto depth=Input(resource,FG_ResourceType::Depth);
        XeFGProxy::resourceResult=-14;assert(!s.SetResource(&depth));
        assert(!s._frameResources[0].contains(FG_ResourceType::Depth)&&!s._resourceReady[0].contains(FG_ResourceType::Depth));
        assert(!State::Instance().fgChanged && s._recovery.Recovering() && s.IsActive());
        s.PreparePresent();assert(!s.IsActive()&&!XeFGProxy::enabled&&XeFGProxy::disableCalls==1);
        Frame(s,9);XeFGDiagnostics::testNow=63;XeFGProxy::resourceResult=0;assert(!s.SetResource(&depth));
        assert(XeFGProxy::enableCalls==0 && XeFGProxy::tagsWhileDisabled==0);
        XeFGDiagnostics::testNow=64;assert(Fresh(s,10,true));
        assert(XeFGProxy::enableCalls==1&&XeFGProxy::enabled&&s.IsActive());
        assert(XeFGProxy::acceptedMask==7&&XeFGProxy::lastConstantsFrame==10&&XeFGProxy::lastIdFrame==10);
        auto token=s.PresentRecoveryToken();assert(token);
        s.ObservePresentStatus(token,0,0,1,0,true);assert(s._recovery.Recovering());
        assert(Fresh(s,11,true));token=s.PresentRecoveryToken();assert(token);
        s.ObservePresentStatus(token,0,0,6,0,true);assert(!s._recovery.Recovering());
        assert(s._maxInterpolationCount==5&&s._framesToInterpolate==5&&Config::Instance()->FGXeFGInterpolationCount.value==5);
        assert(XeFGProxy::tagsWhileDisabled==0&&s.copyCalls==0&&!State::Instance().fgChanged);
    }
    {
        ResetGlobals();XeFG_Dx12 s;ID3D12Resource resource;auto depth=Input(resource,FG_ResourceType::Depth);
        XeFGProxy::resourceResult=5;assert(!s.SetResource(&depth));
        assert(!s._recovery.Recovering()&&!State::Instance().fgChanged&&!s._frameResources[0].contains(FG_ResourceType::Depth));
        XeFGProxy::resourceResult=0;assert(s.SetResource(&depth));
    }
    for(unsigned failingStage=0;failingStage<3;++failingStage){
        ResetGlobals();XeFG_Dx12 s;
        if(failingStage==0)XeFGProxy::constantsResult=-14;
        if(failingStage==1)XeFGProxy::presentIdResult=-14;
        if(failingStage==2)XeFGProxy::backbufferResult=-14;
        assert(!Fresh(s,100));assert(s._recovery.Recovering()&&s.PresentRecoveryToken()==0&&!State::Instance().fgChanged);
        assert(XeFGProxy::idCalls==(failingStage==0?0u:1u));
        s.PreparePresent();assert(!s.IsActive());
        XeFGProxy::constantsResult=XeFGProxy::presentIdResult=XeFGProxy::backbufferResult=0;
        XeFGDiagnostics::testNow=1000;assert(Fresh(s,101));
        s.ObservePresentStatus(s.PresentRecoveryToken(),0,0,6,0,true);assert(!s._recovery.Recovering());
    }
    {
        ResetGlobals();XeFG_Dx12 s;XeFGProxy::resourceResult=-14;
        ID3D12Resource resource;auto depth=Input(resource,FG_ResourceType::Depth);
        for(uint64_t now=0;now<10000;++now){XeFGDiagnostics::testNow=now;Frame(s,now+100);s.SetResource(&depth);s.PreparePresent();}
        assert(XeFGProxy::tagCalls>1&&XeFGProxy::tagCalls<20);
        assert(XeFGProxy::disableCalls<20&&XeFGProxy::enableCalls<20&&XeFGProxy::tagsWhileDisabled==0);
        assert(!State::Instance().fgChanged&&s.copyCalls==0);
        XeFGProxy::resourceResult=0;XeFGDiagnostics::testNow=20000;assert(Fresh(s,20100));
        s.ObservePresentStatus(s.PresentRecoveryToken(),0,0,6,0,true);assert(!s._recovery.Recovering());
    }
    for(bool failDisable:{false,true}){
        ResetGlobals();XeFG_Dx12 s;s.NoteRecoveryFault(s._frameCount,"pressure_or_provider_error",-14);
        if(failDisable)XeFGProxy::disableResult=-5;else XeFGProxy::enableResult=-5;
        for(uint64_t now=0;now<10000;++now){XeFGDiagnostics::testNow=now;s._frameCount=now+100;s.PreparePresent();s.Activate();}
        if(failDisable){assert(s.IsActive()&&XeFGProxy::enabled&&XeFGProxy::disableCalls<=157&&XeFGProxy::enableCalls==0);}
        else{assert(!s.IsActive()&&!XeFGProxy::enabled&&XeFGProxy::enableCalls>1&&XeFGProxy::enableCalls<20);}
        XeFGProxy::disableResult=XeFGProxy::enableResult=0;XeFGDiagnostics::testNow=20000;s.PreparePresent();
        XeFGDiagnostics::testNow=22000;assert(Fresh(s,30000));
    }
    {
        ResetGlobals();XeFG_Dx12 s;s.NoteRecoveryFault(s._frameCount,"test",-14);
        std::latch entered{1},go{1};XeFGProxy::controlEntered=&entered;XeFGProxy::controlMayReturn=&go;
        std::thread first([&]{s.PreparePresent();});entered.wait();s.PreparePresent();assert(XeFGProxy::disableCalls==1);
        go.count_down();first.join();XeFGProxy::controlEntered=XeFGProxy::controlMayReturn=nullptr;
        assert(!s.IsActive()&&!XeFGProxy::enabled);
    }
    {
        ResetGlobals();XeFG_Dx12 s;s.NoteRecoveryFault(s._frameCount,"test",-14);s._lifecycleFailed=true;
        s.PreparePresent();s.Activate();assert(XeFGProxy::enableCalls==0&&XeFGProxy::disableCalls==0);
        ID3D12Resource r;auto d=Input(r,FG_ResourceType::Depth);assert(!s.SetResource(&d));
        s._lifecycleFailed=false;assert(s._workGate.TryCloseWhenIdle());s.PreparePresent();s.Activate();assert(!s.SetResource(&d));
        assert(XeFGProxy::enableCalls==0&&XeFGProxy::disableCalls==0);assert(s._workGate.Open());
        s.PreparePresent();assert(XeFGProxy::disableCalls==1);
    }
    {
        ResetGlobals();XeFG_Dx12 s;assert(Fresh(s,40));auto old=s.PresentRecoveryToken();assert(old);
        s.PreparePresent();s.ObservePresentStatus(old,0,0,1,-14,true);
        assert(!s._recovery.Recovering()); // old dispatch cannot turn unrelated Present into an error.
        assert(Fresh(s,41));s.ObservePresentStatus(s.PresentRecoveryToken(),0,0,1,-14,true);
        assert(s._recovery.Recovering());s.PreparePresent();assert(!s.IsActive());
        XeFGDiagnostics::testNow=1000;assert(Fresh(s,42));
        s.ObservePresentStatus(s.PresentRecoveryToken(),0,0,6,0,true);assert(!s._recovery.Recovering());
        assert(Fresh(s,43));s.ObservePresentStatus(s.PresentRecoveryToken(),0,0,1,0,false);
        assert(!s._recovery.Recovering());
        assert(Fresh(s,44));s.ObservePresentStatus(s.PresentRecoveryToken(),0,0,1,0,false);
        assert(s._recovery.Recovering());
    }
    for(int terminal:{-1,-2,-3,-7,-8,-11,-16}){
        ResetGlobals();XeFG_Dx12 s;ID3D12Resource resource;auto depth=Input(resource,FG_ResourceType::Depth);
        XeFGProxy::resourceResult=terminal;assert(!s.SetResource(&depth));s.PreparePresent();
        assert(s._recovery.State()==XeFGRecovery::Phase::Stopped);
        for(uint64_t frame=100;frame<1100;++frame){XeFGDiagnostics::testNow=frame*1000;Frame(s,frame);s.Activate();s.PreparePresent();assert(!s.SetResource(&depth));}
        assert(XeFGProxy::tagCalls==1&&XeFGProxy::enableCalls==0&&XeFGProxy::disableCalls==1);
    }
    for(unsigned location=0;location<3;++location){
        ResetGlobals();XeFG_Dx12 s;
        if(location==0){s._isActive=false;XeFGProxy::enabled=false;XeFGProxy::enableResult=-2;}
        else {
            s.NoteRecoveryFault(s._frameCount,"transient",-14);
            if(location==1)XeFGProxy::disableResult=-2;
            else {s.PreparePresent();XeFGProxy::enableResult=-2;}
        }
        for(uint64_t frame=100;frame<1100;++frame){XeFGDiagnostics::testNow=frame*1000;s._frameCount=frame;s.PreparePresent();s.Activate();}
        assert(s._recovery.State()==XeFGRecovery::Phase::Stopped && "terminal SDK control failure requires a new context");
        assert(XeFGProxy::enableCalls<=1&&XeFGProxy::disableCalls<=2);
    }
    {
        ResetGlobals();XeFG_Dx12 s;s.NoteRecoveryFault(s._frameCount,"test",-14);s.PreparePresent();
        XeFGDiagnostics::testNow=64;Frame(s,10,2);assert(s.TryBeginRecoveryTrial(10));
        auto token=s.PresentRecoveryToken();assert(token);s.ObservePresentStatus(token,0,0,6,0,true);
        assert(s._recovery.State()==XeFGRecovery::Phase::Trial); // no coherent inputs; output alone cannot heal
        token=s.PresentRecoveryToken();s.ObservePresentStatus(token,0,0,1,-14,true);
        assert(s._recovery.State()==XeFGRecovery::Phase::Trial && XeFGProxy::disableCalls==1);
        token=s.PresentRecoveryToken();s.ObservePresentStatus(token,0,0,1,0,false);
        assert(s._recovery.State()==XeFGRecovery::Phase::Trial);
        token=s.PresentRecoveryToken();s.ObservePresentStatus(token,0,0,1,0,false);
        assert(s._recovery.State()==XeFGRecovery::Phase::NeedDisable);
    }
    {
        ResetGlobals();XeFG_Dx12 s;ID3D12Resource color,depth,mv;auto h=Input(color,FG_ResourceType::HudlessColor);
        h.validity=FG_ResourceValidity::UntilPresentFromDispatch;assert(s.SetResource(&h));
        color.format=87;XeFGProxy::resourceResult=-14;assert(!s.SetResource(&h));
        assert(s._hudlessObservedFormat[0]==87&&s._hudlessAcceptedFormat[0]==28);
        s.PreparePresent();XeFGProxy::resourceResult=0;XeFGDiagnostics::testNow=64;Frame(s,12);s.MarkFrameConstantsReady(12);
        auto d=Input(depth,FG_ResourceType::Depth),v=Input(mv,FG_ResourceType::Velocity);
        assert(s.SetResource(&d)&&s.SetResource(&v)&&s.SetResource(&h));
        assert(s._hudlessAcceptedFormat[0]==87&&!State::Instance().fgChanged);
        s.PreparePresent();assert(s.Dispatch());s.ObservePresentStatus(s.PresentRecoveryToken(),0,0,6,0,true);
        assert(!s._recovery.Recovering());
    }
    std::cout<<"PASS: actual SetResource/Dispatch/control/status recovery pipeline, persistent failures and bounded retries\n";
}
