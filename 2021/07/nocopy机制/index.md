# no copy机制


在`sync`包下面经常出现"XXX must not be copied after first use."，然后下面就有一个`noCopy`。

## 什么是noCopy ?

如果结构体对象包含指针字段，当该对象被拷贝时，会使得两个对象中的指针字段变得不再安全。

```go
type S struct {
 f1 int
 f2 *s
}

type s struct {
 name string
}

func main() {
 mOld := S{
  f1: 0,
  f2: &s{name: "mike"},
 }
 mNew := mOld //拷贝
 mNew.f1 = 1
 mNew.f2.name = "jane"

 fmt.Println(mOld.f1, mOld.f2) //输出：0 &{jane}
}
```

修改`nNew`字段的值会把`mOld`字段的值修改掉，这就会引发安全问题。

## 如果保证noCopy

### runtime checking

#### copy检查

```go
func main() {
	var a strings.Builder
	a.Write([]byte("a"))
	b := a
	b.Write([]byte("b"))
}
// 运行报错： panic: strings: illegal use of non-zero Builder copied by value
```

报错信息来自于`strings.Builder`的`copyCheck`

```go
// Do not copy a non-zero Builder.
type Builder struct {
	addr *Builder // of receiver, to detect copies by value
	buf  []byte
}

func (b *Builder) Write(p []byte) (int, error) {
	b.copyCheck()
	b.buf = append(b.buf, p...)
	return len(p), nil
}

func (b *Builder) copyCheck() {
	if b.addr == nil {
		// This hack works around a failing of Go's escape analysis
		// that was causing b to escape and be heap allocated.
		// See issue 23382.
		// TODO: once issue 7921 is fixed, this should be reverted to
		// just "b.addr = b".
		b.addr = (*Builder)(noescape(unsafe.Pointer(b)))
	} else if b.addr != b {
		panic("strings: illegal use of non-zero Builder copied by value")
	}
}
```

在`Builder`中，`addr`是一个指向自身的指针。如果`a`复制给`b`，那么`a`和`b`本身是不同的对象。因此`b.addr`实际上是指向`a`，就会导致`panic`.

#### sync.Cond中的copy检查

```go
type copyChecker uintptr

func (c *copyChecker) check() {
	if uintptr(*c) != uintptr(unsafe.Pointer(c)) &&
		!atomic.CompareAndSwapUintptr((*uintptr)(c), 0, uintptr(unsafe.Pointer(c))) &&
		uintptr(*c) != uintptr(unsafe.Pointer(c)) {
		panic("sync.Cond is copied")
	}
}
```

当被拷贝后，uintptr(*c)和uintptr(unsafe.Pointer(c))的值是不同的，通过uint对象的原子比较方法CompareAndSwapUintptr将返回false，它证明了对象a被copy过，从而调用panic保护sync.Cond不被复制。

### go vet checking

上面的两个都是在程序编译时，`runtime`进行检查的。

```go
// noCopy may be embedded into structs which must not be copied
// after the first use.
//
// See https://golang.org/issues/8005#issuecomment-190753527
// for details.
type noCopy struct{}

// Lock is a no-op used by -copylocks checker from `go vet`.
func (*noCopy) Lock()   {}
func (*noCopy) Unlock() {}
```

sync包下的其他的对象如Pool、WaitGroup、Mutex、Map等，它们都存在copy检查机制。

通过`go vet`进行copy检查。

那么我们可以参考Go源码的`noCopy`，实现调用不能拷贝

```go
type noCopy struct{}
func (*noCopy) Lock() {}
func (*noCopy) Unlock() {}
type MyType struct {
   noCopy noCopy
   ...
}
```


