---
title: "sync之Map"
date: 2021-07-16T10:53:02+08:00
draft: false

tags: ['analysis','sync']
categories: ["go"]
comment: true
toc: true
autoCollapseToc: false
---

我们都知道map是不并发安全的，通常通过加互斥锁或读写锁进行并发，而官方提供了一个解决方案`sync.Map`。适用于读多写少的场景，那么它的内部也是通过加锁控制的吗？

## 一、写时复制(COW)

在Linux程序中，fork（）会产生一个和父进程完全相同的子进程，但子进程在此后多会exec系统调用，出于效率考虑，linux中引入了“写时复制“技术，也就是只有进程空间的各段的内容要发生变化时，才会将父进程的内容复制一份给子进程。

写时复制技术：内核只为新生成的子进程创建虚拟空间结构，它们来复制于父进程的虚拟究竟结构，但是不为这些段分配物理内存，它们共享父进程的物理空间，当父子进程中有更改相应段的行为发生时，再为子进程相应的段分配物理空间。

其实我们之前已经见过这种方式了，就是[字符串的赋值](https://www.toutiao.com/i7040810615639851533/)，底层赋值是直接用指针替代的。

## 二、并发安全

### 1、常用的几种并发安全的map

| 实现方式   | 原理                                             | 常用场景                                 |
| ---------- | ------------------------------------------------ | ---------------------------------------- |
| map+互斥锁 | 通过Mutex互斥锁来实现map的串行访问               | 读写都需要加锁，适用于读写比较接近的场景 |
| map+读写锁 | 通过RWMutex读写锁对map读写加锁，使并发读性能提高 | 读多写少的场景                           |
| `sync.Map` | 底层通过读写分离来实现读的无锁                   | 读多写少的场景                           |

因为go没有泛型，所以使用`interface{}`能匹配所有数据。

`sync.Map`对以下两种常用场景进行了优化：

- entry只写一次但是读很多次，比如只增长的缓存
- 多个goroutine在读写entry，互不干扰

在这两种情况下，使用`sync.Map`比单独使用互斥锁或读写锁的map好。

### 2、数据结构

```go
type Map struct {
	mu Mutex
	read atomic.Value // readOnly
	dirty map[interface{}]*entry
	misses int
}
```

- 当涉及到脏数据时，需要用到锁
- `read`中包含了map内容中对并发访问是安全的部分，存储在`read`中的`entry`可以在没有锁的情况下并发更新，但是更新前删除的`entry`需要将`entry`复制给`dirty`，并保证不被删除。
- `ditry`包含了部分键值对，而`dirty`中的元素最终都会被赋值给`read`
- `misses`就是计数器，用于记录`read`中没有而在`dirty`中存在的数量，当`misses`=`len(dirty)`，那么就会把`dirty`迁移到`read`中。

而`read`的指针指向的是`readOnly`结构体

```go
type readOnly struct {
	m map[interface{}]*entry
	amended bool 
}
```

这个`amended`是个标志位，如果为`ture`表明当前`read`只读数据`m`不完整，`dirty`中包含部分数据。

`entry`其实就是个指针，有以下几种情况：

- `nil`：`entry`被删除，并且`m.dirty`为空
- `expunged`：`entry`被删除，但`m.dirty`不为空，也不在`m.dirty`中
- 其他：正常值，指向了`interface{}`值，并记录在`m.read.m[key]`中

## 三、操作

### 1、查找

#### 1.1、无锁读

```go
read, _ := m.read.Load().(readOnly)
e, ok := read.m[key]
if !ok {
	return nil, false
}
```

优先从`read`的map中查找，如果没有找到就是不存在。此时从`read`中读取是不加锁的，是不影响性能的。

#### 1.2、读写分离

```go
if !ok && read.amended {
	m.mu.Lock()
	read, _ = m.read.Load().(readOnly)
	e, ok = read.m[key]
	if !ok && read.amended {
		e, ok = m.dirty[key]
		m.missLocked()
	}
	m.mu.Unlock()
}
```

如果没有找到，并且标识`dirty`中存在数据，那么就要从`dirty`中查找，而在`dirty`操作时是需要加锁的。

这里有一点要特别注意，在加锁后，重新判断了一个`read`，这个是**二次检查**，防止在加锁之前，`dirty`已经迁移到`read`中。

在进入`dirty`查找时，不管有没有找到，都要使`misses`+1，因为去`dirty`查找了一次。

如果`misses`大于`dirty`的长度，那么就开始迁移`dirty`的数据到`read`中。

### 2、新增/更新

#### 2.1、更新

```go
read, _ := m.read.Load().(readOnly)
if e, ok := read.m[key]; ok && e.tryStore(&value) {
	return
}
```

先读取`read`，如果存在`key`，就尝试更新。这一步也是不加锁的

#### 2.2、新增

如果不存在，那就要新增`key`了。新增这一步就需要加锁了

```go
read, _ = m.read.Load().(readOnly)
if e, ok := read.m[key]; ok {
	if e.unexpungeLocked() {
		m.dirty[key] = e
	}
	e.storeLocked(&value)
} else if e, ok := m.dirty[key]; ok {
	e.storeLocked(&value)
} else {
	if !read.amended { 
		m.dirtyLocked()
		m.read.Store(readOnly{m: read.m, amended: true})
	}
	m.dirty[key] = newEntry(value) 
}
```

而这里对应着以下场景

- 如果在`read`中，而`key`对应的`value`标识是已删除，那么先去`dirty`中添加，然后再更新
- 如果不在`read`中，在`dirty`中，直接更新值
- 如果都不存在，那么就把数据存在`dirty`中，然后修改`read`中的标志位。如果此时`dirty`没有数据，那么就从`read`中复制数据，并把标识为删除的数据清除。

这里在`dirty`写数据，不影响`read`中读取的数据，可以保证读取`read`的时候并发安全。

### 3、删除

看到这里，应该很容易推理出删除的逻辑

1、从`read`中查找`key`是否存在，如果不存在但是标志位显示`dirty`中有新数据，那么就加锁去`dirty`中查看，然后清除`key`。

2、如果真不存在，就结束

3、如果存在`read`中，就将`entry`置`nil`

---

其他几种方法，如`LoadOrStore`，`Range`就很容易知道是如何实现的了。

## 四、生命周期

以上，我们就能分析出key的生命周期

1、新增操作，将`key`保存在`dirty`中，并且标识`read`数据不完整

2、查询操作，在`dirty`中找到了`key`，并且满足迁移的条件，将`dirty`移到`read`中，修改标识，`read`数据完整

3、查询操作，直接在`read`中查询到`key`了

4、更新操作，直接在`read`中更新`key`

5、删除操作，把`key`对应的`value`置为nil

6、新增其他的`key1`，触发迁移条件，将`read`的数据复制到`dirty`中，此时`key`对应的`value`==`nil`，被修改为`expunged`，并且不添加到`dirty`中。

7、在下一次满足将`dirty`迁移到`read`中，就会将这个不存在的`key`删除

## 四、总结

1、空间换时间：通过两个冗余的数据结构(`read`，`dirty`)，减少锁对性能的影响

2、读操作尽量在`read`中进行，避免读写冲突

3、命中到`dirty`累加`misses`的值，当超出限制时，迁移`dirty`，避免`dirty`数据过多

4、二次检查，避免在非原子操作时产生数据错误

5、延迟删除，删除一个键值对只是打了个标签，只有在迁移到`read`中才清除删除的数据

6、优先从read中读、改和删除，因为对read的操作不用加锁，大大提升性能