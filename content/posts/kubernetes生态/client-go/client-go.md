---
title: "client-go架构"
date: 2022-03-07T13:32:36+08:00
draft: false

tags: ['kubernetes','client-go']
categories: ["note"]
comment: true
toc: true
autoCollapseToc: false
---

以下是`client-go`的官方架构图

![client-go-controller-interaction](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2022/01/10/client-go-controller-interaction.jpeg)

## 一、Indexer

`Indexer`保存来自`api-server`的资源，使用`list-watch`方式来维护资源的增量变化。通过这种方式可以减少对`api-server`的访问，减少`api-server`端的压力。

`Indexer`继承`Store`接口，使用多个索引扩展`Store`并限制每个累加器仅保存当前对象(在Delete后为空)。

`Store`接口定义了对象的增删改查等方法。

而`cache`实现了`Indexer`接口，它定义了线程安全和key的序列化方法

```go
type cache struct {
	cacheStorage ThreadSafeStore
	keyFunc KeyFunc
}
```

而`ThreadSafeStore`是一个允许对后台存储进行并发访问的接口，类似于`Indexer`，但是不需要知道如何从对象obj中取出key。

通过`NewStore`和`NewIndexer`初始化cache返回`Store`或`Indexer`指针。

- indexer实际的对象存储在`threadSafeMap`中
- `indexers`划分了不同类型的索引值(indexName，如namespace)，并按照索引类型进行索引(indexFunc，如`MetaNamespaceIndexFunc`)，得到符合该对象的索引键，一个对象在一个索引类型中可以有多个索引键
- items的键值对保存了实际对象

以`namespace`为索引类型，

1、从`indexers`获取计算`namespace`的`IndexFunc`

2、用`IndexFunc`计算入参obj相关的所有namespaces，`indeices`中保存了所有namespaces下面的对象键，可以获取特定namespace下的对象键

3、在`items`中可以通过对象键得到对象

## 二、DeltaFIFO

DeltaFIFO是一个生产者-消费者队列，生产者为Reflector，消费者为`Pop()`方法。

`DeltaFIFO`实现了`Queue`和`Store`接口，使用`Deltas`保存对象状态的变更(Add/Delete/Update)，Deltas缓存了针对相同对象的多个状态变更信息，如Delta[0]存储了pod的更新，最老的状态变更为`Oldest()`，最新的状态变更为`Newest`。

其中`knownObjects`类型为`KeyListerGetter`，接口方法`ListKeys`和`GetByKey`也是`Store`接口中的方法，而实际上，`knownObjects`也是使用`Store/Indexer`来初始化的，也就是说可以通过`ListKeys`和`GetByKey`方法获取`Store/Indexer`中的对象键。

`initialPopulationCount`表示是否完成全量同步，在`Replace`增加，在`Pop`减少，当`initialPopulationCount=0`且`populated=true`表示`Pop`了所有的`Replace`添加到`DeltaFIFO`对象，`populated`用于判断是DeltaFIFO中是否为初始化状态(即没有处理过任何对象).

> 在`NewSharedIndexInformer`中初始化了`sharedIndexInformer`，用`NewIndexer`初始化`Indexer`，在`Run`方法中用`s.indexer`作为`DeltaFIFO`的`knowObjects`。

`DeltaFIFO`实现了`Queue`接口。

在`list-watch`的`list`步骤中，会调用`Replace`方法来对`DeltaFIFO`进行全量更新：

1、`Sync`所有`DeltaFIFO`中的对象，全部加入到`DeltaFIFO`中

2、如果`knownObjects`为空，则删除`DeltaFIFO`中不存在的对象，

3、如果`knownObjects`非空，获取`knownObjects`中不存在的对象，在`DeltaFIFO`删除

## 三、List-Watch

`Lister`用于获取某个资源的全量，`Watcher`用于获取某个资源的增量变化。

实际使用中Lister和Watcher都从apiServer获取资源信息，Lister一般用于首次获取某资源(如Pod)的全量信息，而Watcher用于持续获取该资源的增量变化信息。

在例子的workqueue可以看到调用`NewListWatchFromClient`的地方

```go
podListWatcher := cache.NewListWatchFromClient(clientset.CoreV1().RESTClient(), "pods", v1.NamespaceDefault, fields.Everything())
```

而这个资源名称在`k8s.io/api/core/v1/types.go`中定义。

其中`clientset`中定义`API group`，这些都定义在`client-go/kubernetes/typed`中。

返回的`RESTClient()`返回值为`Interface`接口类型，封装了对资源的操作方法。

```go
type Interface interface {
	GetRateLimiter() flowcontrol.RateLimiter
	Verb(verb string) *Request
	Post() *Request
	Put() *Request
	Patch(pt types.PatchType) *Request
	Get() *Request
	Delete() *Request
	APIVersion() schema.GroupVersion
}
```

而在`List-Watch`的`List`时就调用了`Get`方法。

## 四、Reflector

`Reflector`使用`ListerWatcher`获取资源，将其保存在`store`中，这里的`store`就是`DeltaFIFO`。

`ListAndWatch`在`Reflector.Run`启动，并以`resyncPeriod`周期性调度。

在List时获取资源的首个resourceVersion值，在Watch时获取资源的增量变化，然后将获取到的resourceVersion保存起来

## 五、WorkQueue

用于保存infromer中handler处理后的数据。

## 六、Controller

```go
type controller struct {
	config         Config
	reflector      *Reflector
	reflectorMutex sync.RWMutex
	clock          clock.Clock
}
```

config中的Queue就是DeltaFIFO。

Controller定义了如何调度Reflector。

Controller的运行就是执行了`Reflector.Run`，相当于启动了一个`DeltaFIFO`的生产者，使用`wait.Until`启动一个消费者。

```go
wg.StartWithChannel(stopCh, r.Run)

wait.Until(c.processLoop, time.Second, stopCh)
```

`processLoop`运行了`DeltaFIFO.Pop`方法，消费`DeltaFIFO`对象，如果运行失败会重新添加`AddIfNotPresent`。

## 七、ShareInformer

一个是启动了Controller，一个是注册了`process`的handler方法，`run`方法接受`nextCh`的值，将其作为参数传给handler处理，而`pop`将`addCh`中的元素传送给`pendingNotifications`，并读取元素，传给`nextCh`。

也就是说`pop`负责管理数据，`run`负责处理数据。

这个`handler`就是例子中写的`AddFunc`，`UpdateFunc`，`DeleteFunc`

## 七、总结



