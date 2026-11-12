type: Changed

**Arrays with holes stay compact**: a script that deletes an element inside an array, or writes a little past its end (an array filled from its last index), keeps the elements in one block instead of turning the array into a slow table of properties. Only an array written very far past its end becomes such a table.
