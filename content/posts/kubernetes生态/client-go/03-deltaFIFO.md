---
title: "client-go之队列"
date: 2022-03-07T13:32:36+08:00
draft: false

tags: ['kubernetes','client-go']
categories: ["月霜天的小笔记"]
comment: true
toc: true
autoCollapseToc: false
---

![client-go-controller-interaction](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2022/01/10/client-go-controller-interaction.jpeg)

看这个`client-go`的架构图，`DeltaFIFO`是一个生产者-消费者队列，生产者是`Reflector`，消费者是`Pop()`方法。

## 一、DeltaFIFO

`Delta`是存储的元数据，能够了解到数据的变化。

```go
type Delta struct {
	Type   DeltaType
	Object interface{}
}

type Deltas []Delta
```

`DeltaType`记录了数据变化的类型

```go
type DeltaType string

// Change type definition
const (
	Added   DeltaType = "Added"
	Updated DeltaType = "Updated"
	Deleted DeltaType = "Deleted"
	Replaced DeltaType = "Replaced"
	Sync DeltaType = "Sync"
)
```

`DeltaFIFO`的定义 ：

```go
type DeltaFIFO struct {
	lock sync.RWMutex
	cond sync.Cond
	items map[string]Deltas
	queue []string
	populated bool
	initialPopulationCount int
	keyFunc KeyFunc
	knownObjects KeyListerGetter
	closed bool
	emitDeltaTypeReplaced bool
}
```

- `item`：按照key-value存储对象，value是`Delta`数组
- `queue`：先入先出的队列，存储的是对象的key
- `populated`：标识第一次将对象放入队列，或第一次调用增删改接口时为true
- `initialPopulationCount`：第一次对象放入队列的数量
- `keyFunc`：对象键计算函数
- `knownObjects`：指向Indexer

### 1.1、`KeyListerGetter`

`KeyListerGetter`是一个通用的接口，定义了返回所有的key和通过key获取对象两个方法。

```go
type KeyListerGetter interface {
	KeyLister
	KeyGetter
}

type KeyLister interface {
	ListKeys() []string
}

type KeyGetter interface {
	GetByKey(key string) (value interface{}, exists bool, err error)
}
```

### 1.2、Queue

`DeltaFIFO`是实现了`Queue`接口，`Queue`继承了`Store`接口，可以让对象有序弹出。

```go
type Queue interface {
	Store
	Pop(PopProcessFunc) (interface{}, error)
	AddIfNotPresent(interface{}) error
	HasSynced() bool
	Close()
}
```

### 1.3、数据状态

`Deltas`是数组，存储数据变更状态，例如0号位存储最老的状态，末位存储最新的状态。

```go
func (d Deltas) Oldest() *Delta {
	if len(d) > 0 {
		return &d[0]
	}
	return nil
}

func (d Deltas) Newest() *Delta {
	if n := len(d); n > 0 {
		return &d[n-1]
	}
	return nil
}
```

### 1.4、初始化

有两种方法初始化，一种是通过`Indexer`的`keyFunc`和它的存储方法初始化

```go
func NewDeltaFIFO(keyFunc KeyFunc, knownObjects KeyListerGetter) *DeltaFIFO {
	return NewDeltaFIFOWithOptions(DeltaFIFOOptions{
		KeyFunction:  keyFunc,
		KnownObjects: knownObjects,
	})
}
```

另一种方法是通过选项初始化

```go
type DeltaFIFOOptions struct {
	KeyFunction KeyFunc
	KnownObjects KeyListerGetter
	EmitDeltaTypeReplaced bool
}

func NewDeltaFIFOWithOptions(opts DeltaFIFOOptions) *DeltaFIFO {
	if opts.KeyFunction == nil {
		opts.KeyFunction = MetaNamespaceKeyFunc
	}

	f := &DeltaFIFO{
		items:        map[string]Deltas{},
		queue:        []string{},
		keyFunc:      opts.KeyFunction,
		knownObjects: opts.KnownObjects,

		emitDeltaTypeReplaced: opts.EmitDeltaTypeReplaced,
	}
	f.cond.L = &f.lock
	return f
}
```

## 二、Queue

### 2.1、`KeyOf`

计算`Deltas`对象的key，最终使用的是`Indexer`的`keyFunc`方法。

```go
func (f *DeltaFIFO) KeyOf(obj interface{}) (string, error) {
	if d, ok := obj.(Deltas); ok {
		if len(d) == 0 {
			return "", KeyError{obj, ErrZeroLengthDeltasObject}
		}
		obj = d.Newest().Object
	}
	if d, ok := obj.(DeletedFinalStateUnknown); ok {
		return d.Key, nil
	}
	return f.keyFunc(obj)
}
```

### 2.2、List

`List`返回对象的最新版本

```go
func (f *DeltaFIFO) List() []interface{} {
	f.lock.RLock()
	defer f.lock.RUnlock()
	return f.listLocked()
}

func (f *DeltaFIFO) listLocked() []interface{} {
	list := make([]interface{}, 0, len(f.items))
	for _, item := range f.items {
		list = append(list, item.Newest().Object)
	}
	return list
}
```

`ListKeys`返回对象的键

```go
func (f *DeltaFIFO) ListKeys() []string {
	f.lock.RLock()
	defer f.lock.RUnlock()
	list := make([]string, 0, len(f.queue))
	for _, key := range f.queue {
		list = append(list, key)
	}
	return list
}
```

### 2.3、GET

`Get`获取对象接口，用对象获取对象

```go
func (f *DeltaFIFO) Get(obj interface{}) (item interface{}, exists bool, err error) {
	key, err := f.KeyOf(obj)
	if err != nil {
		return nil, false, KeyError{obj, err}
	}
	return f.GetByKey(key)
}
```

`GetByKey`通过对象键获取对象

```go
func (f *DeltaFIFO) GetByKey(key string) (item interface{}, exists bool, err error) {
	f.lock.RLock()
	defer f.lock.RUnlock()
	d, exists := f.items[key]
	if exists {
		// Copy item's slice so operations on this slice
		// won't interfere with the object we return.
		d = copyDeltas(d)
	}
	return d, exists, nil
}
```

### 2.4、Add/Update/Delete

增删改操作都是调用的`queueActionLocked`方法，删除方法多了一步就是在`item`里删除对象

```go
func (f *DeltaFIFO) Add(obj interface{}) error {
	f.lock.Lock()
	defer f.lock.Unlock()
	f.populated = true
	return f.queueActionLocked(Added, obj)
}

func (f *DeltaFIFO) Update(obj interface{}) error {
	f.lock.Lock()
	defer f.lock.Unlock()
	f.populated = true
	return f.queueActionLocked(Updated, obj)
}

func (f *DeltaFIFO) Delete(obj interface{}) error {
	id, err := f.KeyOf(obj)
	if err != nil {
		return KeyError{obj, err}
	}
	f.lock.Lock()
	defer f.lock.Unlock()
	f.populated = true
	if f.knownObjects == nil {
		if _, exists := f.items[id]; !exists {
			return nil
		}
	} else {
		_, exists, err := f.knownObjects.GetByKey(id)
		_, itemsExist := f.items[id]
		if err == nil && !exists && !itemsExist {
			return nil
		}
	}

	return f.queueActionLocked(Deleted, obj)
}
```

在`queueActionLocked`方法中，Add/Update/Delete操作其实都需要保存下来，记录在`Deltas`

```go
func (f *DeltaFIFO) queueActionLocked(actionType DeltaType, obj interface{}) error {
	id, err := f.KeyOf(obj)
	if err != nil {
		return KeyError{obj, err}
	}
	oldDeltas := f.items[id]
	newDeltas := append(oldDeltas, Delta{actionType, obj})
	newDeltas = dedupDeltas(newDeltas)

	if len(newDeltas) > 0 {
		if _, exists := f.items[id]; !exists {
			f.queue = append(f.queue, id)
		}
		f.items[id] = newDeltas
		f.cond.Broadcast()
	} else {
		if oldDeltas == nil {
			return nil
		}
		f.items[id] = newDeltas
		return fmt.Errorf("Impossible dedupDeltas for id=%q: oldDeltas=%#+v, obj=%#+v; broke DeltaFIFO invariant by storing empty Deltas", id, oldDeltas, obj)
	}
	return nil
}
```

- 首先计算出资源对象的key
- 将`actionType`和资源对象构造成`Delta`，通过`dedupDeltas`去重
- 将新的`Deltas`添加进`items`中，通过`cond.Broadcast`通知所有的消费者接触阻塞

另一个方法`AddIfNotPresent`，看名字就能知道，如果不存在就新增

```go
func (f *DeltaFIFO) AddIfNotPresent(obj interface{}) error {
	deltas, ok := obj.(Deltas)
	if !ok {
		return fmt.Errorf("object must be of type deltas, but got: %#v", obj)
	}
	id, err := f.KeyOf(deltas)
	if err != nil {
		return KeyError{obj, err}
	}
	f.lock.Lock()
	defer f.lock.Unlock()
	f.addIfNotPresent(id, deltas)
	return nil
}

func (f *DeltaFIFO) addIfNotPresent(id string, deltas Deltas) {
	f.populated = true
	if _, exists := f.items[id]; exists {
		return
	}

	f.queue = append(f.queue, id)
	f.items[id] = deltas
	f.cond.Broadcast()
}
```

### 2.5、Replace

原子性地做两件事：保存数据；删除不存在的数据

```go
func (f *DeltaFIFO) Replace(list []interface{}, _ string) error {
	f.lock.Lock()
	defer f.lock.Unlock()
	keys := make(sets.String, len(list))

	action := Sync
	if f.emitDeltaTypeReplaced {
		action = Replaced
	}

	for _, item := range list {
		key, err := f.KeyOf(item)
		if err != nil {
			return KeyError{item, err}
		}
		keys.Insert(key)
		if err := f.queueActionLocked(action, item); err != nil {
			return fmt.Errorf("couldn't enqueue object: %v", err)
		}
	}

	if f.knownObjects == nil {
		queuedDeletions := 0
		for k, oldItem := range f.items {
			if keys.Has(k) {
				continue
			}
			var deletedObj interface{}
			if n := oldItem.Newest(); n != nil {
				deletedObj = n.Object
			}
			queuedDeletions++
			if err := f.queueActionLocked(Deleted, DeletedFinalStateUnknown{k, deletedObj}); err != nil {
				return err
			}
		}
		// 首次添加
		if !f.populated {
			f.populated = true
			f.initialPopulationCount = keys.Len() + queuedDeletions
		}

		return nil
	}

	knownKeys := f.knownObjects.ListKeys()
	queuedDeletions := 0
	for _, k := range knownKeys {
		if keys.Has(k) {
			continue
		}

		deletedObj, exists, err := f.knownObjects.GetByKey(k)
		if err != nil {
			deletedObj = nil
		} else if !exists {
			deletedObj = nil
		}
		queuedDeletions++
		if err := f.queueActionLocked(Deleted, DeletedFinalStateUnknown{k, deletedObj}); err != nil {
			return err
		}
	}

	if !f.populated {
		f.populated = true
		f.initialPopulationCount = keys.Len() + queuedDeletions
	}

	return nil
}
```

这里对`knownObjects`也就是是否存在`Indexer`，如果没有就在`items`里查找不存在的数据，如果有就去`Indexer`中查找不存在的数据。

### 2.6、Resync



