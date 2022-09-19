---
title: "map三步曲之三实际应用"
date: 2022-03-07T11:16:04+08:00
draft: false

tags: ['map','analysis']
categories: ["go"]
comment: true
toc: true
autoCollapseToc: false
---

之前已经介绍过了[map的原理](https://www.toutiao.com/i7038589955723035143/)，简单了解一下[map里存储的数据结构](https://www.toutiao.com/i7039631036778742305/)。本文主要介绍如果在map中进行操作。

## 一、查找

元素的查找有三种方式：

- `v := m[k]`：对应的`mapaccess1`方法
- `v,ok := m[k]`：对应的`mapaccess2`方法
- `for k,v := range m`：对应的是`mapaccessK`方法

这几种方法的逻辑基本相同，`mapaccessK`的逻辑更简单一些。我们主要说一下`mapaccess1`过程。

### 1、初始条件

```go
if h == nil || h.count == 0 {
	if t.hashMightPanic() {
		t.hasher(key, 0) // see issue 23734
	}
	return unsafe.Pointer(&zeroVal[0])
}
```

判断map是否为空，或者元素个数是否为0，如果是，返回零值。

### 2、读写判断

```go
if h.flags&hashWriting != 0 {
	throw("concurrent map read and map write")
}
```

如果`flags`是`hashWriting`，那么表示map是正在写，会报错。不能进行并发写操作。

### 3、找到bucket

```go
hash := t.hasher(key, uintptr(h.hash0))
m := bucketMask(h.B)
b := (*bmap)(add(h.buckets, (hash&m)*uintptr(t.bucketsize)))
if c := h.oldbuckets; c != nil {
	if !h.sameSizeGrow() {
		m >>= 1
	}
	oldb := (*bmap)(add(c, (hash&m)*uintptr(t.bucketsize)))
	if !evacuated(oldb) {
		b = oldb
	}
}

top := tophash(hash)
```

先对key进行`hash`，然后根据这个`hash`值获取对应`bucket`号，和`tophash`值。

如果此时`oldbuckets`不为空，说明发生了扩容。

如果有扩容发生，老的`buckets`中的数据还没有搬迁到新的`buckets`中，所以要先在`oldbuckets`中查找。

### 4、在bucket中查找key

```go
for ; b != nil; b = b.overflow(t) {
	for i := uintptr(0); i < bucketCnt; i++ {
		if b.tophash[i] != top {
			if b.tophash[i] == emptyRest {
				break bucketloop
			}
			continue
		}
		k := add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
		if t.indirectkey() {
			k = *((*unsafe.Pointer)(k))
		}
		if t.key.equal(key, k) {
			e := add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.elemsize))
			if t.indirectelem() {
				e = *((*unsafe.Pointer)(e))
			}
			return e
		}
	}
}
```

在这个bucket及其溢出桶中查找，`bucketCnt`=8。

遍历桶元素，因为桶中的key是使用连续的存储空间存储，因此可以直接使用bucket+数据偏移量+keysize的大小得到k的位置，如果找到的这个位置和key相同，那么就能以相同的方法得到value。

## 二、赋值

如果key不存在，那么就需要在bucket对key进行赋值。

### 1、初始条件

```go
if h == nil {
	panic(plainError("assignment to entry in nil map"))
}
```

肯定不能对没有初始化过的map进行赋值

### 2、读写判断

```go
if h.flags&hashWriting != 0 {
	throw("concurrent map writes")
}
```

不能进行并发写

### 3、设置写标识

```go
hash := t.hasher(key, uintptr(h.hash0))
h.flags ^= hashWriting
if h.buckets == nil {
	h.buckets = newobject(t.bucket) // newarray(t.bucket, 1)
}
```

这步标记map进入写状态，不允许进行读操作

### 4、找到bucket

```go
bucket := hash & bucketMask(h.B)
b := (*bmap)(unsafe.Pointer(uintptr(h.buckets) + bucket*uintptr(t.bucketsize)))
top := tophash(hash)
```

### 5、找到可以放置的位置

这里分成两种情况

- cell的`tophash`值和当前`tophash`值不等，可能会存在一个空槽位

```
[h0][h1][h2][h3][h4][e][e][e]
after delete
[h0][h1][e ][e ][h5][e][e][e]
```

在执行删除后，可能会在前面留有空位，这里把这个空位记录下来，如果后面没有找到相同的key，就在这里插入

- cell的`tophash`值和当前`tophash`值相等，更新它

如果在这个bucket没有找到，就去它的溢出桶中查找

### 6、搬迁和扩容

这个在下面详细介绍

### 7、重置读写标识

```go
if h.flags&hashWriting == 0 {
	throw("concurrent map writes")
}
h.flags &^= hashWriting
if t.indirectelem() {
	elem = *((*unsafe.Pointer)(elem))
}
```

## 三、删除

删除map中的key ：`delete(m, key)`

主要流程和查找流程差不多，找到key的位置，清除bucket槽位的key和value

```go
if t.indirectkey() {
	*(*unsafe.Pointer)(k) = nil
} else if t.key.ptrdata != 0 {
	memclrHasPointers(k, t.key.size)
}
```

如果是指针的话，置`nil`，如果是值的话，清空内存

## 四、扩容

为了保证访问效率，在添加、修改或删除key时，都会检查是否扩容。

扩容其实就是空间换时间的过程。

map的扩容条件有两种情况：

1、判断已经达到装载因子，即元素个数 >= 桶总数 * 6.5

```go
func overLoadFactor(count int, B uint8) bool {
	return count > bucketCnt && uintptr(count) > loadFactorNum*(bucketShift(B)/loadFactorDen)
}
```

2、判断溢出桶是否太多。

当桶总数<2^15^时，如果溢出桶>=桶总数，则认为溢出桶过多。

当桶总数>2^15^时，与2^15^比较，如果溢出桶>=2^15^，则认为溢出桶过多。

```go
func tooManyOverflowBuckets(noverflow uint16, B uint8) bool {
	if B > 15 {
		B = 15
	}
	return noverflow >= uint16(1)<<(B&15)
}
```

在某些场景下，比如不断的增删，这样会造成溢出桶增多，但是负载因子不高，没有到达装载因子的临界值，这样就会导致桶的使用率不高，值存得稀疏，查找插入效率低。因此有了第二种情况的判断。

---

- 增量扩容：针对第一种情况，新建一个`bucket`，新的`bucket`大小是原来的2倍，然后`oldbuckets`搬迁数据到`newbuckets`。
- 等量扩容：针对第二种情况，不扩大容量，`buckets`数量不变，重新做一次搬迁数据的操作，把松散的键值对重新排列一次。

在源码中，和扩容相关的主要是`hashGrow`和`growWork`函数。

`hashGrow`函数并没有真正"搬迁"，只是分配好新的`buckets`，并将老的`buckets`挂到`oldbuckets`下。

`growWork`函数才是真正进行“搬迁”操作，而调用`growWork`函数的是`mapassign`和`mapdelete`中。也就是说在插入、修改、删除key的时候，才会真正尝试进行`buckets`的“搬迁”工作。它们都会先检查`oldbuckets`是否“搬迁”完成(`oldbuckets == nil`)，再决定是否进行搬迁工作。

```go
func growWork(t *maptype, h *hmap, bucket uintptr) {
	// 为了确认搬迁的bucket是我们正在使用的bucket
	// 即如果当前key映射到老的bucket，那么就搬迁该bucket
	evacuate(t, h, bucket&h.oldbucketmask())
	// 如果还未完成扩容
	if h.growing() {
		evacuate(t, h, h.nevacuate)
	}
}
```

---

在搬迁过程中，我们会发现如下问题：

- 如果是等量扩容，那么原key所在的桶和扩容后所在的桶不变，因此可以按照桶号进行搬迁。

  ![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/10/map_sameGrow.png)

- 如果是增量扩容，桶号就有可能发生变化。

  ![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/10/map_notSameGrow.png)

所以在`evacuate`中，有`bucket x`和`bucket y`的区别，其实就是增量扩容到原来的2倍，桶的数量是原来的2倍，前半桶为`bucket x`，后半桶为`bucket y`。

## 五、总结

1、map是哈希表实现，通过链地址法解决哈希冲突，核心数据结构是数组加链表。

2、map中定义了2^B^个桶，每个桶中能容纳8个key。根据key的不同哈希值，将其散落到不同的桶中。哈希值的低位（哈希值的后B个bit位）决定桶号，高位（哈希值的前8位）标识同一个桶中的不同key。桶中8个key是连续存储的，8个value也是连续存储的，是为了内存对齐。

3、当向桶中添加很多key，造成元素过多，超过装载因子所设定的程度，或频繁增删操作，造成溢出桶过多，会触发扩容机制。

扩容分为增量扩容和等量扩容。

- 增量扩容，会增加桶的个数（增加一倍），把原来一个桶中的 keys 被重新分配到两个桶中。

- 等量扩容，不会更改桶的个数，只是会将桶中的数据变得紧凑。

  不管是增量扩容还是等量扩容，都需要创建新的桶数组，并不是原地操作的。

4、扩容过程是渐进性的，每次最多搬迁2个bucket，主要是防止扩容需要搬迁的 key 数量过多，引发性能问题。触发扩容的时机是增加了新元素， 桶搬迁的时机则发生在赋值、删除期间。

5、遍历map无序是因为`map`在扩容后，会发生key的搬迁，这就造成原来在一个bucket中的key，可能搬迁到其他bucket中，所以遍历map肯定不可能按原来的顺序。所以map在遍历的时候，并不是从0号bucket开始，每次都是随机值序号的bucket，再从其中随机的`cell`开始遍历，然后再按照桶序继续，直到遍历完成。