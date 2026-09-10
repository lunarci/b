// Regression harness for the actual callback selector blocks extracted from
// OptiScaler 7daf5d042d32412da407838cd59e0869ecaaa55e and the candidate patch.
// Portable stand-ins cover COM ownership and frame registry behavior only.
// They do not execute Direct3D, AMD code, or the whole OptiScaler DLL.
#include <atomic>
#include <cassert>
#include <iostream>
#include <mutex>
#include <shared_mutex>
#include <thread>
#include <unordered_map>
#include <utility>
enum class FG_ResourceType { HudlessColor };
enum class FG_ResourceValidity { ValidNow, UntilPresent };
enum D3D12_RESOURCE_STATES { D3D12_RESOURCE_STATE_COPY_DEST = 1,
 D3D12_RESOURCE_STATE_UNORDERED_ACCESS = 2,
 D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE = 4 };
struct ID3D12Resource {
 int id;
 std::atomic<int> refs{1};
 bool destroyed = false;
 explicit ID3D12Resource(int n): id(n) {}
 void AddRef() { assert(!destroyed); refs++; }
 void Release() { assert(refs > 0); if (--refs == 0) destroyed=true; }
};
namespace Microsoft::WRL {
template<class T> class ComPtr {
 T* p=nullptr;
 public:
 ComPtr()=default;
 ComPtr(const ComPtr& x):p(x.p) { if(p)p->AddRef(); }
 ComPtr(ComPtr&& x) noexcept :p(std::exchange(x.p,nullptr)) {}
 ComPtr& operator=(T* v) {
  if(v)v->AddRef();
  if(p)p->Release();
  p=v; return *this;
 }
 ~ComPtr(){if(p)p->Release();}
 T* Get() const{return p;}
};
}
struct Dx12Resource {
 ID3D12Resource* resource=nullptr;
 ID3D12Resource* copy=nullptr;
 D3D12_RESOURCE_STATES state=D3D12_RESOURCE_STATE_COPY_DEST;
 FG_ResourceValidity validity=FG_ResourceValidity::ValidNow;
 ID3D12Resource* GetResource(){return copy ? copy : resource;}
};
struct LockedDx12Resource {
 Dx12Resource* resource=nullptr;
 std::shared_lock<std::shared_mutex> lock;
 Dx12Resource* operator->(){return resource;}
 explicit operator bool()const{return resource!=nullptr;}
};
struct Selection {
 Microsoft::WRL::ComPtr<ID3D12Resource> owner;
 ID3D12Resource* resource=nullptr;
 D3D12_RESOURCE_STATES state=D3D12_RESOURCE_STATE_COPY_DEST;
};
struct Registry {
 std::unordered_map<FG_ResourceType,Dx12Resource> _frameResources[4];
 std::unordered_map<FG_ResourceType,ID3D12Resource*> _resourceCopy[4];
 std::shared_mutex _resourceMutex[4];
 LockedDx12Resource GetResource(FG_ResourceType type,int index) {
  std::shared_lock lock(_resourceMutex[index]);
  auto& resources=_frameResources[index];
  auto it=resources.find(type);
  if(it!=resources.end()) return {&it->second,std::move(lock)};
  return {nullptr,std::move(lock)};
 }
 void set(Dx12Resource r) {
  std::unique_lock lock(_resourceMutex[0]);
  _frameResources[0][FG_ResourceType::HudlessColor]=r;
 }
 void newFrame() {
  std::unique_lock lock(_resourceMutex[0]);
  _frameResources[0].clear();
 }
 Selection before(int fIndex=0) {
        auto hudlessResource = _resourceCopy[fIndex][FG_ResourceType::HudlessColor];
        auto hudlessState = D3D12_RESOURCE_STATE_COPY_DEST;

        if (hudlessResource == nullptr)
        {
            auto hudless = _frameResources[fIndex][FG_ResourceType::HudlessColor];
            if (hudless.validity == FG_ResourceValidity::UntilPresent)
                hudlessResource = hudless.GetResource();

            // hudless.state only holds the state for the original resource, not the copy that we could get here
            if (hudlessResource && hudlessResource == hudless.resource)
                hudlessState = hudless.state;
        }
  return {{},hudlessResource,hudlessState};
 }
 Selection after(int fIndex=0) {
        Microsoft::WRL::ComPtr<ID3D12Resource> hudlessSnapshot;
        auto hudlessState = D3D12_RESOURCE_STATE_COPY_DEST;
        {
            // The current frame record identifies both the selected resource and its state.
            // The reusable copy cache may still contain a resource from an earlier frame.
            auto hudless = GetResource(FG_ResourceType::HudlessColor, fIndex);
            if (hudless && (hudless->copy != nullptr || hudless->validity == FG_ResourceValidity::UntilPresent))
            {
                hudlessSnapshot = hudless->GetResource();
                hudlessState = hudless->state;
            }
        }
        // Retain the snapshot, but release the registry lock before recording commands:
        // command-list hooks may re-enter resource tracking.
        auto hudlessResource = hudlessSnapshot.Get();
  return {hudlessSnapshot,hudlessResource,hudlessState};
 }
};
int main(){
 constexpr auto H=FG_ResourceType::HudlessColor;
 ID3D12Resource direct(1), cached(2), transformed(3), transient(4);
 int fixedFailures=0;
 {
  Registry r;
  r._resourceCopy[0][H]=&cached;
  r.set({&direct,nullptr,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,FG_ResourceValidity::UntilPresent});
  assert(r.before().resource==&cached); // observed incorrect historical-copy choice
  auto selected=r.after();
  assert(selected.resource==&direct);
  assert(selected.state==D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
  fixedFailures++;
 }
 {
  Registry r;
  r.set({&direct,&transformed,D3D12_RESOURCE_STATE_UNORDERED_ACCESS,FG_ResourceValidity::UntilPresent});
  auto old=r.before();
  assert(old.resource==&transformed);
  assert(old.state==D3D12_RESOURCE_STATE_COPY_DEST); // observed wrong barrier before-state
  auto selected=r.after();
  assert(selected.resource==&transformed);
  assert(selected.state==D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
  fixedFailures++;
 }
 {
  Registry r;
  r._resourceCopy[0][H]=&cached;
  r.set({&direct,&cached,D3D12_RESOURCE_STATE_COPY_DEST,FG_ResourceValidity::ValidNow});
  r.newFrame();
  assert(r.before().resource==&cached); // old cache survives frame clear
  const auto sizeBefore=r._frameResources[0].size();
  assert(r.after().resource==nullptr);
  assert(r._frameResources[0].size()==sizeBefore);
  fixedFailures++;
 }
 {
  Registry r;
  r._resourceCopy[0][H]=&cached;
  r.set({&direct,&cached,D3D12_RESOURCE_STATE_COPY_DEST,FG_ResourceValidity::ValidNow});
  assert(r.before().resource==r.after().resource);
  assert(r.before().state==r.after().state); // normal copied-resource path preserved
 }
 {
  Registry r;
  r.set({&transient,nullptr,D3D12_RESOURCE_STATE_COPY_DEST,FG_ResourceValidity::ValidNow});
  assert(r.after().resource==nullptr); // current non-copied transient input remains ineligible
 }
 {
  Registry r;
  r.set({&transient,nullptr,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,FG_ResourceValidity::UntilPresent});
  {
   auto selected=r.after();
   assert(transient.refs==2); // snapshot owns a strong reference before lock ends
   std::atomic<bool> writerAcquired=false;
   std::thread writer([&]{
    // Mirrors a resource-tracking hook re-entering after callback selection.
    std::unique_lock lock(r._resourceMutex[0],std::try_to_lock);
    writerAcquired=lock.owns_lock();
    if(lock.owns_lock()) r._frameResources[0].clear();
   });
   writer.join();
   assert(writerAcquired); // no registry lock is held across command-list/SDK calls
   transient.Release(); // registry producer releases its owner after replacement
   assert(!transient.destroyed);
   assert(selected.resource->id==4);
  }
  assert(transient.destroyed);
 }
 {
  Registry r;
  const auto count=r._frameResources[0].size();
  assert(r.after().resource==nullptr);
  assert(r._frameResources[0].size()==count);
  assert(r._resourceCopy[0].empty()); // selector is read-only on both maps
 }
 std::cout<<"PASS: "<<fixedFailures<<" original selector failures reproduced; "
          <<"current-record selection, resource state, copy eligibility, "
          <<"read-only access, COM retention, and unlocked re-entry verified.\n";
}

