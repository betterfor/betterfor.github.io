# 常见的数据结构--切片


在使用过程中，我们经常会用到数组这一数据结构，而在golang中，提供了数组和切片两种，数组是固定长度的且长度为定值，而切片是可以扩张的数组。

本章内容参考 runtime/slice.go

## 内部数据结构
```go
type slice struct {
    array unsafe.Pointer// 数据
    len int             // 长度
    cap int             // 容量
}
```
我们可以通过下面的代码输出slice：
```go
package main

import (
	"fmt"
	"unsafe"
)

func main() {
	data := make([]int,0,3)

	fmt.Println(unsafe.Sizeof(data),len(data),cap(data))
	// Output: 24,0,3

	// 通过指针方式拿到切片内部的值
	ptr := unsafe.Pointer(&data)
	opt := (*[3]int)(ptr)

	fmt.Println(opt[0],opt[1],opt[2])
	// Output: addr,0,3

	data = append(data, 4)
	fmt.Println(unsafe.Sizeof(data))
	// Output: 24

	shallowCopy := data[:1]
	ptr1 := unsafe.Pointer(&shallowCopy)
	opt1 := (*[3]int)(ptr1)

	fmt.Println(opt1[0])
	// Output: addr
}
```

## 创建
创建一个slice，实质上是在分配内存。
```go
func makeslice(et *_type, len, cap int) unsafe.Pointer {
    // 获取需要申请的内存大小
	mem, overflow := math.MulUintptr(et.size, uintptr(cap))
	if overflow || mem > maxAlloc || len < 0 || len > cap {
		mem, overflow := math.MulUintptr(et.size, uintptr(len))
		if overflow || mem > maxAlloc || len < 0 {
			panicmakeslicelen() // 超过内存限制|超过最大分配量|长度小于0
		}
		panicmakeslicecap() // 长度大于容量
	}
    // 分配内存
    // runtime/malloc.go
	return mallocgc(mem, et, true)
}
```

## 扩容机制
golang中内置了`copy`函数，可以用来拷贝切片。
```go
func growslice(et *_type, old slice, cap int) slice {
    // 静态分析
	if raceenabled {
		callerpc := getcallerpc()
		racereadrangepc(old.array, uintptr(old.len*int(et.size)), callerpc, funcPC(growslice))
	}
	if msanenabled {
		msanread(old.array, uintptr(old.len*int(et.size)))
	}
	
	if cap < old.cap {
		panic(errorString("growslice: cap out of range"))
	}
    
    // 如果新切片的长度为0，返回空数据，长度为旧切片的长度
	if et.size == 0 {
		return slice{unsafe.Pointer(&zerobase), old.len, cap}
	}

	newcap := old.cap
	doublecap := newcap + newcap
	if cap > doublecap { // 如果容量大于原有容量的2倍，则按新增容量申请
		newcap = cap
	} else {
		if old.len < 1024 { // 如果原有容量小于1024，新容量是原有容量的2倍
			newcap = doublecap
		} else { // 原有容量大于1024，按原有容量的1.25倍递增，直到满足需求
			for 0 < newcap && newcap < cap {
				newcap += newcap / 4
			}
			if newcap <= 0 { // 校验容量是否溢出
				newcap = cap
			}
		}
	}

	var overflow bool
	var lenmem, newlenmem, capmem uintptr
	// 为加速计算（不用乘除法）
    // 对于2的幂，使用变位处理
	switch {
	case et.size == 1:
		lenmem = uintptr(old.len)
		newlenmem = uintptr(cap)
		capmem = roundupsize(uintptr(newcap))
		overflow = uintptr(newcap) > maxAlloc
		newcap = int(capmem)
	case et.size == sys.PtrSize:
		lenmem = uintptr(old.len) * sys.PtrSize
		newlenmem = uintptr(cap) * sys.PtrSize
		capmem = roundupsize(uintptr(newcap) * sys.PtrSize)
		overflow = uintptr(newcap) > maxAlloc/sys.PtrSize
		newcap = int(capmem / sys.PtrSize)
	case isPowerOfTwo(et.size): // 2的幂
		var shift uintptr
		if sys.PtrSize == 8 {
			// Mask shift for better code generation.
			shift = uintptr(sys.Ctz64(uint64(et.size))) & 63
		} else {
			shift = uintptr(sys.Ctz32(uint32(et.size))) & 31
		}
		lenmem = uintptr(old.len) << shift
		newlenmem = uintptr(cap) << shift
		capmem = roundupsize(uintptr(newcap) << shift)
		overflow = uintptr(newcap) > (maxAlloc >> shift)
		newcap = int(capmem >> shift)
	default:
		lenmem = uintptr(old.len) * et.size
		newlenmem = uintptr(cap) * et.size
		capmem, overflow = math.MulUintptr(et.size, uintptr(newcap))
		capmem = roundupsize(capmem)
		newcap = int(capmem / et.size)
	}

	// 判断是否会溢出
	if overflow || capmem > maxAlloc {
		panic(errorString("growslice: cap out of range"))
	}

    // 内存分配
	var p unsafe.Pointer
	if et.ptrdata == 0 {
		p = mallocgc(capmem, nil, false)
		// 回收内存
		memclrNoHeapPointers(add(p, newlenmem), capmem-newlenmem)
	} else {
		// Note: can't use rawmem (which avoids zeroing of memory), because then GC can scan uninitialized memory.
		p = mallocgc(capmem, et, true)
		if lenmem > 0 && writeBarrier.enabled { // gc
			// Only shade the pointers in old.array since we know the destination slice p
			// only contains nil pointers because it has been cleared during alloc.
			bulkBarrierPreWriteSrcOnly(uintptr(p), uintptr(old.array), lenmem)
		}
	}
    // 数据拷贝
	memmove(p, old.array, lenmem)

	return slice{p, old.len, newcap}
}
```

### 深拷贝
```go
func slicecopy(to, fm slice, width uintptr) int {
	if fm.len == 0 || to.len == 0 {
		return 0
	}

	n := fm.len
	if to.len < n {
		n = to.len
	}
    // 元素长度为0，直接返回
	if width == 0 {
		return n
	}

    // 竞态分析和内存扫描
	if raceenabled {
		callerpc := getcallerpc()
		pc := funcPC(slicecopy)
		racewriterangepc(to.array, uintptr(n*int(width)), callerpc, pc)
		racereadrangepc(fm.array, uintptr(n*int(width)), callerpc, pc)
	}
	if msanenabled {
		msanwrite(to.array, uintptr(n*int(width)))
		msanread(fm.array, uintptr(n*int(width)))
	}

	size := uintptr(n) * width
    // 拷贝内存
	if size == 1 { // common case worth about 2x to do here
		// TODO: is this still worth it with new memmove impl?
		*(*byte)(to.array) = *(*byte)(fm.array) // known to be a byte pointer
	} else {
		memmove(to.array, fm.array, size)
	}
	return n
}

// 字符串slice拷贝
func slicestringcopy(to []byte, fm string) int {
	if len(fm) == 0 || len(to) == 0 {
		return 0
	}

	n := len(fm)
	if len(to) < n {
		n = len(to)
	}

	if raceenabled {
		callerpc := getcallerpc()
		pc := funcPC(slicestringcopy)
		racewriterangepc(unsafe.Pointer(&to[0]), uintptr(n), callerpc, pc)
	}
	if msanenabled {
		msanwrite(unsafe.Pointer(&to[0]), uintptr(n))
	}

	memmove(unsafe.Pointer(&to[0]), stringStructOf(&fm).str, uintptr(n))
	return n
}

```
