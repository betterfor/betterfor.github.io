---
title: "client-go之索引"
date: 2022-03-07T13:32:36+08:00
draft: false

tags: ['kubernetes','client-go']
categories: ["月霜天的小笔记"]
comment: true
toc: true
autoCollapseToc: false
---

以下是`client-go`的官方架构图

![client-go-controller-interaction](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2022/01/10/client-go-controller-interaction.jpeg)

先主要针对这个`Indexer`来分析。

## 一、Indexer

`Indexer`保存来自`api-server`的资源，通过`list-watch`的方式来维护资源的增量变化，以这种方式来减少对`api-server`的直接访问，降低`api-server`的访问压力。

```go
type Indexer interface {
	Store
    // 返回索引值值集和给定对象的索引值集相交的对象列表
	Index(indexName string, obj interface{}) ([]interface{}, error)
    // 返回索引值集
	IndexKeys(indexName, indexedValue string) ([]string, error)
    // 返回已经索引的所有索引值
	ListIndexFuncValues(indexName string) []string
    // 返回索引值对象
	ByIndex(indexName, indexedValue string) ([]interface{}, error)
    // 返回所有的索引
	GetIndexers() Indexers
    // 添加新的索引方法
	AddIndexers(newIndexers Indexers) error
}
```

`Indexer`继承了`Store`的接口，使用多个索引扩展`Store`并限制存储(在删除后置空)。

它存储了三样内容：

1、存储的key，使用定义`Store`的接口

2、索引名称

3、索引值，用`IndexFunc`方法生成，这个方法使用资源对象的值来生成的。

这里有定义几个类型

```go
type IndexFunc func(obj interface{}) ([]string, error)
type Index map[string]sets.String
type Indexers map[string]IndexFunc
type Indices map[string]Index
```

而接口`Store`定义了对象的方法

```go
type Store interface {
	Add(obj interface{}) error
	Update(obj interface{}) error
	Delete(obj interface{}) error
	List() []interface{}
	ListKeys() []string
	Get(obj interface{}) (item interface{}, exists bool, err error)
	GetByKey(key string) (item interface{}, exists bool, err error)
	Replace([]interface{}, string) error
	Resync() error
}
```

很明显，这个就是存储的增删改查的方法

## 二、cache

cache是`Indexer`接口的实现，所有对象都保存在这个`cache`中。

```go
type cache struct {
	cacheStorage ThreadSafeStore
	keyFunc KeyFunc
}
```

定义了一个线程安全存储和一个计算对象键的函数。

```go
func MetaNamespaceKeyFunc(obj interface{}) (string, error) {
	if key, ok := obj.(ExplicitKey); ok {
		return string(key), nil
	}
	meta, err := meta.Accessor(obj)
	if err != nil {
		return "", fmt.Errorf("object has no meta: %v", err)
	}
	if len(meta.GetNamespace()) > 0 {
		return meta.GetNamespace() + "/" + meta.GetName(), nil
	}
	return meta.GetName(), nil
}
```

这个就是大部分使用的`KeyFunc`方法，就是取对象的元数据`namespace/name`。

看这个线程安全存储`ThreadSafeStore`。从定义上来看，增删改查的功能都是通过这个类型实现的

```go
type ThreadSafeStore interface {
	Add(key string, obj interface{})
	Update(key string, obj interface{})
	Delete(key string)
	Get(key string) (item interface{}, exists bool)
	List() []interface{}
	ListKeys() []string
	Replace(map[string]interface{}, string)
	Index(indexName string, obj interface{}) ([]interface{}, error)
	IndexKeys(indexName, indexKey string) ([]string, error)
	ListIndexFuncValues(name string) []string
	ByIndex(indexName, indexKey string) ([]interface{}, error)
	GetIndexers() Indexers

	// AddIndexers adds more indexers to this store.  If you call this after you already have data
	// in the store, the results are undefined.
	AddIndexers(newIndexers Indexers) error
	// Resync is a no-op and is deprecated
	Resync() error
}
```

看起来和`Indexer`很类似，但是还有有点区别的。`Indexer`操作的都是资源对象，而`ThreadSafeStore`操作的是需要提供对象键的。

```go
type threadSafeMap struct {
	lock sync.RWMutex
	// key to value
	items map[string]interface{}
	// 计算索引键的map
	indexers Indexers
	// 快速索引表，可以通过索引快速找到对象键，然后再从items中取出对象
	indices Indices
}
```

而初始化实例的方法就是初始化`threadSafeMap`结构

```go
func NewThreadSafeStore(indexers Indexers, indices Indices) ThreadSafeStore {
	return &threadSafeMap{
		items:    map[string]interface{}{},
		indexers: indexers,
		indices:  indices,
	}
}
```

它的方法列表中都是关于`items`的增删改查，这部分没什么好说的，主要是对索引的更新。

## 三、实例

看到这几个定义索引的类型，用个例子来理解

```go
func testIndexFunc(obj interface{}) ([]string, error) {
	pod := obj.(*v1.Pod)
	return []string{pod.Labels["foo"]}, nil
}

func main() {
	index := NewIndexer(MetaNamespaceKeyFunc, Indexers{"testmodes": testIndexFunc})

	pod1 := &v1.Pod{ObjectMeta: 
                    metav1.ObjectMeta{Name: "one", Labels: map[string]string{"foo": "bar"}}}
	pod2 := &v1.Pod{ObjectMeta: 
                    metav1.ObjectMeta{Name: "two", Labels: map[string]string{"foo": "bar"}}}
	pod3 := &v1.Pod{ObjectMeta: 
                    metav1.ObjectMeta{Name: "tre", Labels: map[string]string{"foo": "biz"}}}

	index.Add(pod1)
	index.Add(pod2)
	index.Add(pod3)

	keys := index.ListIndexFuncValues("testmodes")
	if len(keys) != 2 {
		log.Fatalf("Expected 2 keys but got %v", len(keys))
	}

	for _, key := range keys {
		if key != "bar" && key != "biz" {
			log.Fatalf("Expected only 'bar' or 'biz' but got %s", key)
		}
	}
}
```

## 四、总结

所有的对象(Pod、Service等)都有属性标签(Annotations/Labels)，如果属性标签就是索引键，`Indexer`就会把相同的属性标签的所有对象放在一个集合中，`items`用来存放这些资源对象，而`indexers`是存储索引方法，比如说就是取对象的`namespace`，`indices`就是索引表，key对应的是不同的`namespace`，`value`对应的就是资源对象名称集合。