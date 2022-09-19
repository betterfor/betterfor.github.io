---
title: "并发编程之Map"
date: 2021-07-16T10:53:02+08:00
draft: false

tags: ['analysis','sync']
categories: ["go"]
comment: true
toc: true
autoCollapseToc: false
---

golang原生的`map`是不支持并发，而在`sync/map`是线程安全的，可以并发读写，适用于读多写少的场景。

`sync.Map`是Go `map[interface{}]interface{}`，它对两种常用的场景进行了优化：

1、entry只写一次，但读很多次，比如在只增长的缓存中

2、多个goroutine读写、更新entry互不干扰

在这两种情况下，使用`sync.Map`比`map`加互斥锁性能要更好。

## 基本的数据结构

```go
type Map struct {
	// 当涉及到脏数据（dirty）操作时，需要用锁
	mu Mutex

	read atomic.Value // readOnly

	// dirty 包含部分map键值对，如果需要操作需要mutex获取锁
	// 最后 dirty 中的元素会被全部提升到read里的map去
	dirty map[interface{}]*entry

	// 计数器，用于记录read中没有的而在dirty中有的数据的数量。
	// 也就是说如果read不包含这个数据，会从dirty中读取，misses+1
	// 当misses的数量等于dirty的长度，就会将dirty中的数据迁移到read中
	misses int
}
```

- `read`包含了map内容中对并发访问是安全的部分（不管有没有mu）。读取字段本身总是安全的，但必须和mu一起存储。存储在read中的Entries可以在没有锁的情况下并发更新，但是更新之前删除的entry需要将entry复制到dirty，并且保证不被删除
- `dirty` 包含部分map键值对，如果需要操作需要mutex获取锁，最后 dirty 中的元素会被全部提升到read里的map去
- `misses`计数器，用于记录read中没有的而在dirty中有的数据的数量。也就是说如果read不包含这个数据，会从dirty中读取，misses+1，当misses的数量等于dirty的长度，就会将dirty中的数据迁移到read中

来看看`dirty`，是一个map类型的数据，键类型是`interface{}`，而值的类型是`entry`，其结构如下：

```go
type entry struct {
    p unsafe.Pointer // *interface{}
}
```

p指针指向entry的interface{}值

- nil:entry已经被删除，并且m.dirty为空
- expunged:entry已经被删除，但m.dirty不为空，也不在m.dirty
- 其他:entry是有效的，是个正常值，并记录在m.read.m[key],并且m.dirty != nil, 在 m.dirty[key].

而`read`实际上指向`readonly`结构，相比于`dirty`多了个`amended`属性，用来表示是否存在key不存在于`readonly`，而存在于`dirty`。

```go
type readOnly struct {
	m map[interface{}]*entry
	amended bool // true if the dirty map contains some key not in m.
}
```

而操作这个`sync.Map`的方法有`Load`，`Store`，`LoadOrStore`，`Delete`，`Range`这几个方法。

## 查找Load

```go
func (m *Map) Load(key interface{}) (value interface{}, ok bool) {
	// 从read的map中查找
	read, _ := m.read.Load().(readOnly)
	e, ok := read.m[key]
	// 如果没有找到，并且read.amended=true，说明dirty中有新数据，从dirty中查找，需要加锁
	if !ok && read.amended {
		m.mu.Lock()
		// 在read中再检查一遍，防止加锁的时候dirty已经迁移到read中（二次检查）
		read, _ = m.read.Load().(readOnly)
		e, ok = read.m[key]
		if !ok && read.amended {
			e, ok = m.dirty[key]
			// 不管是否存在，记录misses+1，满足条件后将dirty中数据迁移到read中
			m.missLocked()
		}
		m.mu.Unlock()
	}
	if !ok {
		return nil, false
	}
	return e.load()
}

func (e *entry) load() (value interface{}, ok bool) {
	p := atomic.LoadPointer(&e.p)
	if p == nil || p == expunged {
		return nil, false
	}
	return *(*interface{})(p), true
}

func (m *Map) missLocked() {
	m.misses++
	if m.misses < len(m.dirty) { // misses小于dirty的长度，就不迁移数据
		return
	}
	m.read.Store(readOnly{m: m.dirty})
	m.dirty = nil
	m.misses = 0
}
```

读取的时候先从`read`中读取，如果`read`中不存在，则加锁从`dirty`中读取，并且使用`missLocked`使得`misses`+1。

如果计数器`misses`的数量大于`dirty`的长度，则把`dirty`的数据更新到`read`中。

## 新增和更新Store

```go
func (m *Map) Store(key, value interface{}) {
	// 从read map中如果能找到key，update
	read, _ := m.read.Load().(readOnly)
	if e, ok := read.m[key]; ok && e.tryStore(&value) {
		return
	}

	// 上锁之后重新check一下read map的内容(二次读写)
	m.mu.Lock()
	read, _ = m.read.Load().(readOnly)
	// 场景一：如果在read中，而key对应的value标识是已删除（需要先在dirty中添加），更新这个值
	if e, ok := read.m[key]; ok {
		if e.unexpungeLocked() {
			// The entry was previously expunged, which implies that there is a
			// non-nil dirty map and this entry is not in it.
			m.dirty[key] = e
		}
		e.storeLocked(&value)
		// 场景二：如果不在read中，在dirty中，直接更新值
	} else if e, ok := m.dirty[key]; ok {
		e.storeLocked(&value)
		// 场景三：都不存在，那么把数据存在dirty中，并且修改read中的标识
	} else {
		if !read.amended { // dirty没有新数据
			// We're adding the first new key to the dirty map.
			// Make sure it is allocated and mark the read-only map as incomplete.
			// 从read中复制未删除的数据
			m.dirtyLocked()
			// 更改状态
			m.read.Store(readOnly{m: read.m, amended: true})
		}
		m.dirty[key] = newEntry(value) // 加入dirty中
	}
	m.mu.Unlock()
}
```

`map`的并发读写容易出问题，是因为存值、删除、取值的过程中存在扩容的过程。如果不对`map`进行修改就能提高执行效率。

所以`read`和`dirty`使用的`map`类型就是`map[interface{}]*entry`，值是一个指针，通过对指针的操作来改变值的状态，而不是直接删除或赋值。

而`Stroe`第一步，如果`key`在`read`中存在，那么通过`tryStore`方法来修改值

```go
func (e *entry) tryStore(i *interface{}) bool {
	for {
		p := atomic.LoadPointer(&e.p)
		if p == expunged {
			return false
		}
		if atomic.CompareAndSwapPointer(&e.p, p, unsafe.Pointer(i)) {
			return true
		}
	}
}
```

这里使用了`CAS`，乐观锁。相当于对`map`中每个已经存在的值的修改使用乐观锁，相比于对整个`map`使用锁来说，提高了效率。

`Store`第二步，如果没有更新成功或不在`read`中，则按照逻辑继续往下走。

- 在`read`中，没有更新成功，是因为值类型被标记为已删除，那么就在`dirty`中添加这个键值对
- 如果不在`dirty`，那么在`dirty`中更新值
- 如果不在`dirty`中，那么在`dirty`中存储键值对，如果`dirty`相比于`read`没有新的数据，那么`dirtyLocked`方法将`read`中的数据保存进`dirty`中，并且修改`read`中的状态`amended`

> 由于`map[interface{}]*entry`是一个指针，对`read`里的值修改时，`dirty`中的值也会被修改，因为两个指向的是同一个对象。

## 删除Delete

```go
func (m *Map) Delete(key interface{}) {
	read, _ := m.read.Load().(readOnly)
	e, ok := read.m[key]
	if !ok && read.amended { // 不存在read中，并且dirty有新数据
		m.mu.Lock()
		read, _ = m.read.Load().(readOnly)
		e, ok = read.m[key]
		if !ok && read.amended {
			delete(m.dirty, key) // 加锁删除dirty的数据
		}
		m.mu.Unlock()
	}
	if ok {
		// 在read中存在key
		e.delete()
	}
}
```

删除操作比较简单

- 如果在`read`中，直接删除
- 如果不在`read`中，并且`dirty`没有新数据，直接返回
- 如果不在`read`中，并且`dirty`有新数据，那么就去`dirty`中删除

## 其他

`LoadOrStore`和`Range`这两个方法的逻辑大体和`Load`和`Stroe`类似。

## 总结

1、空间换时间：通过两个冗余的数据结构（read、write），减小锁对性能的影响。

2、读操作使用`read`，写操作使用`dirty`，避免读写冲突。

3、动态调整：通过misses值，避免dirty数据过多。

4、双检查机制：避免在非原子操作时产生数据错误。

5、延迟删除机制：删除一个键值只是先打标记，只有等提升dirty（复制到read中，并清空自身）时才清理删除的数据。

6、优先从read中读、改和删除，因为对read的操作不用加锁，大大提升性能。

