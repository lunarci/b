#include "framegen/xefg/XeFGRecovery.h"
#include <cassert>
#include <cstdint>
#include <iostream>
#include <thread>
#include <vector>
#include <atomic>
using R = XeFGRecovery;

static void Begin(R& policy, uint64_t failed=10, uint64_t trial=11, uint64_t now=0) {
    assert(policy.Fault(failed,now));
    auto disable=policy.DisableTicket(now); assert(disable!=0);
    policy.Disabled(disable,true,now);
    assert(policy.BeginTrial(failed,now+10000)==0);
    assert(policy.BeginTrial(trial,now+63)==0);
    auto enable=policy.BeginTrial(trial,now+64); assert(enable!=0);
    assert(!policy.AllowsInput(trial));
    policy.Enabled(enable,true,now+64);
    assert(policy.State()==R::Phase::Trial && policy.AllowsInput(trial));
    assert(!policy.AllowsInput(failed));
}
static uint64_t Dispatch(R& policy,uint64_t frame,bool hudless=false) {
    policy.ConstantsReady(frame);
    policy.Observe(frame,R::Depth);policy.Accepted(frame,R::Depth);
    policy.Observe(frame,R::Velocity);policy.Accepted(frame,R::Velocity);
    if(hudless) { policy.Observe(frame,R::Hudless);policy.Accepted(frame,R::Hudless); }
    assert(policy.Ready(frame,true));policy.Dispatched(frame);
    const auto token=policy.PresentToken();assert(token!=0);return token;
}
int main() {
    {
        R p;Begin(p);
        // Neither stale data nor mixing two frame identities forms a trial.
        p.ConstantsReady(10);p.Accepted(10,R::Depth);p.Accepted(10,R::Velocity);
        assert(!p.Ready(11,true));
        p.Accepted(11,R::Depth);p.Accepted(12,R::Velocity);p.ConstantsReady(11);
        assert(!p.Ready(11,true) && !p.Ready(12,true));
        p.ConstantsReady(12);assert(!p.Ready(12,true));
        p.Accepted(12,R::Depth);assert(p.Ready(12,true));
        p.Observe(12,R::Hudless);assert(!p.Ready(12,true) && p.Ready(12,false));
        p.Accepted(12,R::Hudless);p.Dispatched(12);assert(p.PresentToken()!=0);
        p.Incomplete(12,R::Velocity);assert(!p.Ready(12,true) && p.PresentToken()==0);
        p.Accepted(12,R::Velocity);p.Dispatched(12);assert(p.PresentToken()!=0);
    }
    {
        R p;Begin(p);uint64_t frame=11;
        auto token=Dispatch(p,frame++);
        assert(p.Presented(token,false,0,6,0,true)==0 && p.Recovering());
        assert(p.Presented(token,true,0,6,0,true)==0); // consumed completion cannot be replayed
        token=Dispatch(p,frame++);assert(p.Presented(token,true,5,6,0,true)==0 && p.Recovering());
        token=Dispatch(p,frame++);assert(p.Presented(token,true,0,6,1,true)==0 && p.Recovering());
        token=Dispatch(p,frame++);assert(p.Presented(token,true,0,0,0,true)==0 && p.Recovering());
        token=Dispatch(p,frame++);
        assert(p.Presented(token,true,0,1,0,true)==0 && p.Recovering()); // base frame is not generated output
        token=Dispatch(p,frame++);assert(p.Presented(token,true,0,2,0,true)==1 && !p.Recovering());
    }
    {
        R p;Begin(p);auto first=Dispatch(p,11);
        assert(p.Presented(first,true,0,1,0,false)==0 && p.Recovering());
        assert(p.Presented(first,true,0,1,0,false)==0); // one result cannot count twice
        auto second=Dispatch(p,12);assert(p.Presented(second,true,0,1,0,false)==-1 && p.Recovering());
        assert(p.Fault(12,100));auto stale=second;
        assert(p.Presented(stale,true,0,6,0,true)==0 && p.Recovering());
        auto disable=p.DisableTicket(100);p.Disabled(disable,true,100);
        auto enable=p.BeginTrial(13,10000);assert(enable);p.Enabled(enable,true,10000);
        auto fresh=Dispatch(p,13);assert(fresh!=stale);
        assert(p.Presented(stale,true,0,6,0,true)==0 && p.Recovering());
        p.Reset();Begin(p,20,21,20000);auto afterReset=Dispatch(p,21);assert(afterReset!=fresh);
        assert(p.Presented(fresh,true,0,6,0,true)==0 && p.Recovering());
        assert(p.Presented(afterReset,true,0,6,0,true)==1);
    }
    {
        R p;assert(p.Fault(1,0));unsigned calls=0;uint64_t previous=0;
        // Ten thousand incoming callbacks cannot become ten thousand disable calls.
        for(uint64_t now=0;now<10000;++now) if(auto ticket=p.DisableTicket(now)) {
            if(calls) assert(now-previous>=64);
            ++calls;previous=now;p.Disabled(ticket,false,now);
            assert(p.State()==R::Phase::NeedDisable && !p.AllowsInput(now+2));
        }
        assert(calls>1 && calls<=157);
        auto ticket=p.DisableTicket(100000);assert(ticket);p.Disabled(ticket,true,100000);
        unsigned enables=0;previous=0;
        for(uint64_t now=100000;now<110000;++now) if(auto probe=p.BeginTrial(now,now)) {
            if(enables) assert(now-previous>=64);
            ++enables;previous=now;p.Enabled(probe,false,now);
            assert(p.State()==R::Phase::Backoff && !p.AllowsInput(now));
        }
        assert(enables>1 && enables<20);
    }
    {
        R p;assert(p.Fault(1,0));auto disable=p.DisableTicket(0);p.Disabled(disable,true,0);
        std::atomic<unsigned> winners{0};std::vector<std::thread> threads;
        for(unsigned i=0;i<32;++i) threads.emplace_back([&]{if(p.BeginTrial(2,1000))++winners;});
        for(auto& t:threads)t.join();assert(winners==1 && p.State()==R::Phase::Enabling);
    }
    {
        R p;Begin(p);Dispatch(p,11);
        p.ConstantsReady(12);p.Accepted(12,R::Depth);
        p.ConstantsReady(13);p.Accepted(13,R::Velocity);
        assert(p.Ready(11,true) && !p.Ready(12,true) && !p.Ready(13,true));
        p.Dispatched(11);auto older=p.PresentToken();assert(older);
        p.PreparePresent();assert(p.PresentToken()==0);
        assert(p.Presented(older,true,0,6,0,true)==0&&p.Recovering());
        p.Dispatched(11);assert(p.Presented(p.PresentToken(),true,0,6,0,true)==1);
        p.Dispatched(14);auto healthy=p.PresentToken();assert(healthy);
        assert(p.Presented(healthy,true,0,1,-14,true)==-1);
    }
    std::cout<<"PASS: production recovery coherent frames, stale completions, truthful output and bounded trial policy\n";
}
