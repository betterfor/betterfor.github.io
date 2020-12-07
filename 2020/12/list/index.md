# 常见的数据结构--链表


提到数据结构，第一个就是链表。通过一组任意的存储单元来存储线性表中的数据元素。



# 链表

链表：**线性表的链式存储**

最简单的链表如下：

```go
package main

import "fmt"

type LinkNode struct {
	data int
	next *LinkNode
}

func main() {
	// 第一个节点
	node1 := new(LinkNode)
	node1.data = 1

	// 第二个节点
	node2 := new(LinkNode)
	node2.data = 2
	node1.next = node2 // node2 链接到 node1 节点上

	// 第三个节点
	node3 := new(LinkNode)
	node3.data = 3
	node2.next = node3 // node3 链接到 node2 节点上

	// 按照顺序打印链表
	newNode := node1
	for newNode != nil {
		fmt.Println(newNode.data)
		newNode = newNode.next
	}
}
```

打印出

```
1
2
3
```

结构体 `LinkNode` 有两个字段，一个是存放数据的`data`，另一个是指向下一个节点`next`。这种从一个节点指向下一个节点的结构，都称为链表。

然后链表又被分为以下几类：

- 单链表：链表是单向的，只有一个方向，不能往会找。元素离散的分布在存储空间中，所以单链表是**非随机存取**的存储结构。
- 双链表：仅仅是在单链表的节点中增加了一个指向其前驱的指针。
- 循环链表：表中最后一个节点的指向不是`null`，而改为指向头节点，从而整个链表形成一个环。

## 实现循环链表

参考标准库 `container/ring.go`

```go
type Ring struct {
	next, prev *Ring       // 前驱节点和后驱节点
	Value      interface{} // 数据
}
```

该结构有三个字段，`next`表示后驱节点，`prev`表示前驱节点，`Value`表示值。

### 初始化循环链表

初始化一个空的循环链表：

```go
package main

type Ring struct {
	next, prev *Ring       // 前驱节点和后驱节点
	Value      interface{} // 数据
}

// 初始化空的循环链表，前驱节点和后驱节点都指向自己
func (r *Ring) init() *Ring {
	r.next = r
	r.prev = r
	return r
}

func main() {
	r := new(Ring)
	r.init()
}
```

因为绑定前驱节点和后驱节点为自己，没有循环，时间复杂度：`O(1)`。

创建一个指定大小`N`的循环链表，值为空：

```GO
func New(n int) *Ring {
	if n <= 0 {
		return nil
	}
	r := new(Ring)
	p := r
	for i := 1; i < n; i++ {
		p.next = &Ring{prev: p}
		p = p.next
	}
	p.next = r
	r.prev = p
	return r
}
```

时间复杂度：`O(n)`。

### 获取上一个或下一个节点

```go
// 获取下一个节点
func (r *Ring) Next() *Ring {
	if r.next == nil {
		return r.init()
	}
	return r.next
}

// 获取上一个基点
func (r *Ring) Prev() *Ring {
	if r.next == nil {
		return r.init()
	}
	return r.prev
}
```

时间复杂度：`O(1)`。

### 获取第n个节点

因为链表是循环的，当`n<0`向前遍历，`n>0`向后遍历。

```go
func (r *Ring) Move(n int) *Ring {
	if r.next == nil {
		return r.init()
	}
	switch {
	case n < 0:
		for ; n < 0; n++ {
			r = r.prev
		}
	case n > 0:
		for ; n > 0; n-- {
			r = r.next
		}
	}
	return r
}
```

时间复杂度：`O(n)`。

### 添加节点

```go
// 往节点r链接一个新的节点，并返回节点r的后驱节点
func (r *Ring) Link(s *Ring) *Ring {
	n := r.Next()
	if s != nil {
		p := s.Prev()
		r.next = s
		s.prev = r
		n.prev = p
		p.next = n
	}
	return n
}
```

假定`s`是一个新的节点，在`r`节点后插一个新的节点`s`，而`r`节点之前的后驱节点，将会链接到新节点后面，并返回`r`节点之前的第一个后驱节点`n`

```go
func main() {
	r := &Ring{Value: 1}
	r.Link(&Ring{Value: 2})
	r.Link(&Ring{Value: 3})
	r.Link(&Ring{Value: 4})
	r.Link(&Ring{Value: 5})

	node := r
	for {
		fmt.Println(node.Value)
		node = node.Next()
		if node == r {
			return
		}
	}
}

// Output
1
5
4
3
2
```

时间复杂度O(1)

### 删除节点

```go
func main() {
	r := &Ring{Value: 1}
	r.Link(&Ring{Value: 2})
	r.Link(&Ring{Value: 3})
	r.Link(&Ring{Value: 4})
	r.Link(&Ring{Value: 5})

	r.Unlink(2)

	node := r
	for {
		fmt.Println(node.Value)
		node = node.Next()
		if node == r {
			return
		}
	}
}

// Output:
1
3
2
```

时间复杂度`O(n)`。

### 链表长度

```go
func (r *Ring) Len() int {
	n := 0
	if r != nil {
		for p := r.Next(); p != r; p = p.next {
			n++
		}
	}
	return n
}
```

时间复杂度: `O(n)`。